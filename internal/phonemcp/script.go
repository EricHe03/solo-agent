//go:build darwin && cgo

package phonemcp

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"log/slog"
	"math"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/nekohasekai/go-sdk/mcp"
	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/deviceserver"
	"github.com/swipt-automation/swipt/internal/jsc"
	"github.com/swipt-automation/swipt/internal/logbuffer"
)

//go:embed meriyah.js
var meriyahSource string

//go:embed prelude.js
var preludeSource string

//go:embed phone.js
var phoneSource string

const imageLimit = 10

var (
	errReset  = E.New("a reset of the JavaScript state interrupted the call")
	errClosed = E.New("the server stopped during the call")
)

type RunnerOptions struct {
	Workflows string
	Logs      *logbuffer.Buffer
	Logger    *slog.Logger
	Dialog    Dialog
}

type Runner struct {
	phone     *deviceserver.Phone
	workflows string
	dialog    Dialog
	logs      *logbuffer.Buffer
	logger    *slog.Logger
	ctx       context.Context
	cancel    context.CancelCauseFunc

	access      sync.Mutex
	epoch       context.Context
	cancelEpoch context.CancelCauseFunc

	busy       chan struct{}
	engine     *engine
	elements   *elementTable
	foreground *foregroundHub
}

func NewRunner(phone *deviceserver.Phone, options RunnerOptions) *Runner {
	logs := options.Logs
	if logs == nil {
		logs = logbuffer.New()
	}
	logger := options.Logger
	if logger == nil {
		logger = slog.New(logs.Handler(slog.DiscardHandler))
	}
	s := &Runner{
		phone: phone, workflows: options.Workflows, dialog: options.Dialog, logs: logs, logger: logger,
		busy: make(chan struct{}, 1), elements: newElementTable(),
	}
	s.ctx, s.cancel = context.WithCancelCause(context.Background())
	s.epoch, s.cancelEpoch = context.WithCancelCause(s.ctx)
	s.foreground = &foregroundHub{ctx: s.ctx, phone: phone, listeners: make(map[chan phoneEvent]struct{})}
	return s
}

type OutputPart struct {
	Text  string
	Image []byte
}

func (s *Runner) Run(ctx context.Context, code string, dialog Dialog) ([]OutputPart, error) {
	return s.execute(ctx, 0, true, func(current *run) {
		current.dialog = dialog
		s.session(current, code)
	}).output()
}

func (s *Runner) RunWorkflow(ctx context.Context, name string, waiting func(), dialog Dialog) ([]OutputPart, error) {
	lock, err := s.lockWorkflow(name)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	return s.execute(ctx, 0, false, func(current *run) {
		current.waiting = waiting
		current.dialog = dialog
		s.runWorkflow(current, name)
	}).output()
}

func (s *Runner) Reset(ctx context.Context) error {
	s.access.Lock()
	s.cancelEpoch(errReset)
	s.epoch, s.cancelEpoch = context.WithCancelCause(s.ctx)
	s.access.Unlock()
	select {
	case s.busy <- struct{}{}:
	case <-ctx.Done():
		return ctx.Err()
	case <-s.ctx.Done():
		return nil
	}
	defer s.unlock()
	if s.engine != nil {
		s.engine.context.Close()
		s.engine = nil
	}
	return nil
}

func (s *Runner) Close() {
	s.cancel(errClosed)
	s.busy <- struct{}{}
	if s.engine != nil {
		s.engine.context.Close()
	}
}

func (s *Runner) lock(ctx context.Context) error {
	select {
	case s.busy <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (s *Runner) unlock() {
	<-s.busy
}

type transcript struct {
	content []mcp.Content
	text    strings.Builder
	images  int
}

func (t *transcript) write(text string) {
	if t.text.Len() > 0 {
		t.text.WriteByte('\n')
	}
	t.text.WriteString(text)
}

func (t *transcript) flush() {
	if t.text.Len() > 0 {
		t.content = append(t.content, &mcp.TextContent{Text: t.text.String()})
		t.text.Reset()
	}
}

func (t *transcript) image(image deviceserver.PhoneImage) error {
	if t.images >= imageLimit {
		return E.New("at most ", imageLimit, " screenshots fit in one call")
	}
	t.images++
	t.flush()
	t.content = append(t.content, &mcp.ImageContent{Data: image.Data, MIMEType: "image/png"})
	return nil
}

type run struct {
	*transcript
	ctx      context.Context
	stop     context.CancelCauseFunc
	timeout  time.Duration
	call     string
	nested   bool
	resident bool
	logger   *slog.Logger
	waiting  func()
	dialog   Dialog
	failed   bool
	failures []string
	settled  bool
	value    string
}

func (r *run) fail(text string) {
	r.failed = true
	if r.logger != nil {
		r.logger.Error(text)
	}
	if r.nested {
		r.failures = append(r.failures, text)
	} else {
		r.write(text)
	}
}

func (r *run) stopped() error {
	switch cause := context.Cause(r.ctx); {
	case errors.Is(cause, context.DeadlineExceeded):
		if r.call != "" {
			return E.New("the script ran past its time limit of ", r.timeout, " during phone.", r.call)
		}
		return E.New("the script ran past its time limit of ", r.timeout)
	case errors.Is(cause, context.Canceled):
		return E.New("the call was cancelled")
	default:
		return cause
	}
}

func (r *run) result() *mcp.CallToolResult {
	r.flush()
	return &mcp.CallToolResult{Content: r.content, IsError: r.failed}
}

func (r *run) output() ([]OutputPart, error) {
	r.flush()
	var texts []string
	var parts []OutputPart
	for _, content := range r.content {
		switch content := content.(type) {
		case *mcp.TextContent:
			texts = append(texts, content.Text)
			parts = append(parts, OutputPart{Text: content.Text})
		case *mcp.ImageContent:
			parts = append(parts, OutputPart{Image: content.Data})
		}
	}
	if r.failed {
		return nil, E.New(strings.Join(texts, "\n"))
	}
	return parts, nil
}

type timer struct {
	id        int
	at        time.Time
	delay     time.Duration
	interval  bool
	callback  jsc.Value
	arguments []jsc.Value
}

func (t *timer) release() {
	t.callback.Release()
	for _, argument := range t.arguments {
		argument.Release()
	}
}

type engine struct {
	runner        *Runner
	context       *jsc.Context
	workflow      string
	elements      *elementTable
	scope         jsc.Value
	rewrite       jsc.Value
	launch        jsc.Value
	format        jsc.Value
	outcome       jsc.Value
	deliver       jsc.Value
	timers        []*timer
	sequence      int
	subscriptions map[int]string
	recordings    map[int]*deviceserver.Recording
	events        chan phoneEvent
	returnTo      string
	run           *run
}

func (s *Runner) newEngine(workflow string, elements *elementTable) (_ *engine, err error) {
	e := &engine{
		runner: s, context: jsc.New(), workflow: workflow, elements: elements,
		subscriptions: make(map[int]string), recordings: make(map[int]*deviceserver.Recording), events: make(chan phoneEvent, eventBacklog),
	}
	defer func() {
		if err != nil {
			e.context.Close()
		}
	}()
	// meriyah clones Identifier and string Literal nodes with structuredClone
	// (meriyah e9b60a0, src/parser/parser.ts:329), which JavaScriptCore defines
	// only in its jsc shell (WebKit 21bb1f66, Source/JavaScriptCore/jsc.cpp:760).
	library, err := e.context.Evaluate("(structuredClone => {"+meriyahSource+"\n})(node => JSON.parse(JSON.stringify(node)))", "meriyah.js")
	if err != nil {
		return nil, err
	}
	library.Release()
	exports, err := e.context.Evaluate(preludeSource, "prelude.js")
	if err != nil {
		return nil, err
	}
	defer exports.Release()
	var describe, sleep jsc.Value
	for _, export := range []struct {
		name  string
		value *jsc.Value
	}{{"rewrite", &e.rewrite}, {"launch", &e.launch}, {"format", &e.format}, {"outcome", &e.outcome}, {"describe", &describe}, {"sleep", &sleep}} {
		*export.value, err = exports.Get(export.name)
		if err != nil {
			return nil, err
		}
	}
	host := e.context.NewObject()
	defer host.Release()
	for _, name := range operations {
		host.SetFunction(name, e.operation(s, name))
	}
	host.SetFunction("print", e.print)
	host.SetFunction("callStarted", func(arguments []jsc.Value) (any, error) {
		call, err := arguments[0].ToString()
		e.run.call = call
		return nil, err
	})
	host.SetFunction("callEnded", func([]jsc.Value) (any, error) {
		e.run.call = ""
		return nil, nil
	})
	host.SetFunction("listen", func(arguments []jsc.Value) (any, error) {
		arguments[0].Protect()
		e.deliver = arguments[0]
		return nil, nil
	})
	host.SetFunction("subscribe", e.subscribe)
	host.SetFunction("unsubscribe", e.unsubscribe)
	host.SetFunction("record", e.record)
	host.SetFunction("stopRecording", e.stopRecording)
	host.SetFunction("fail", func(arguments []jsc.Value) (any, error) {
		text, err := arguments[0].ToString()
		e.run.fail(text)
		return nil, err
	})
	factory, err := e.context.Evaluate(phoneSource, "phone.js")
	if err != nil {
		return nil, err
	}
	defer factory.Release()
	phone, err := factory.Call(host, exports)
	if err != nil {
		return nil, err
	}
	defer phone.Release()
	e.context.SetDescriber(describe)
	// The callback receives the promise and the reason (WebKit 21bb1f66,
	// Source/JavaScriptCore/API/JSContextRefPrivate.h:161).
	e.context.SetUnhandledRejection(func(arguments []jsc.Value) (any, error) {
		e.run.fail("a promise was rejected with nothing to handle it: " + arguments[1].Describe())
		return nil, nil
	})
	console := e.context.NewObject()
	defer console.Release()
	for _, name := range []string{"log", "info", "warn", "error", "debug"} {
		console.SetFunction(name, e.print)
	}
	dialog, err := e.newDialog(exports)
	if err != nil {
		return nil, err
	}
	defer dialog.Release()
	global := e.context.Global()
	global.Set("phone", phone)
	global.Set("dialog", dialog)
	global.Set("console", console)
	global.Set("sleep", sleep)
	global.SetFunction("print", e.print)
	global.SetFunction("setTimeout", e.schedule(false))
	global.SetFunction("setInterval", e.schedule(true))
	global.SetFunction("clearTimeout", e.clear)
	global.SetFunction("clearInterval", e.clear)
	if s.workflows == "" {
		return e, nil
	}
	files := e.context.NewObject()
	defer files.Release()
	for name, function := range e.fileFunctions(s) {
		files.SetFunction(name, function)
	}
	factory, err = e.context.Evaluate(workflowSource, "workflow.js")
	if err != nil {
		return nil, err
	}
	defer factory.Release()
	if workflow == "" {
		e.scope, err = factory.Call(files, exports)
	} else {
		value := e.context.NewString(workflow)
		defer value.Release()
		e.scope, err = factory.Call(files, exports, value)
	}
	if err != nil {
		return nil, err
	}
	name := "workflows"
	if workflow != "" {
		name = "dataFiles"
	}
	value, err := e.scope.Get(name)
	if err != nil {
		return nil, err
	}
	defer value.Release()
	global.Set(name, value)
	return e, nil
}

func (e *engine) execute(current *run, script func() (jsc.Value, error)) {
	e.run = current
	defer func() {
		for _, it := range e.timers {
			it.release()
		}
		e.timers = nil
		clear(e.subscriptions)
		e.runner.foreground.remove(e.events)
		for _, recording := range e.recordings {
			recording.Stop()
		}
		clear(e.recordings)
		e.run = nil
		ctx, cancel := context.WithTimeout(e.runner.ctx, returnTimeout)
		defer cancel()
		if err := e.giveWay(ctx); err != nil {
			e.runner.logger.Warn(err.Error())
		}
	}()
	defer e.context.TerminateOn(current.ctx)()
	err := e.start(current, script)
	for err == nil && (!current.settled || current.resident && e.pending()) {
		if current.settled && current.waiting != nil {
			current.waiting()
			current.waiting = nil
		}
		if !e.pending() {
			current.fail("the script awaits a promise that nothing can settle")
			return
		}
		var wake <-chan time.Time
		var next *timer
		if len(e.timers) > 0 {
			next = common.MinBy(e.timers, func(it *timer) int64 { return it.at.UnixNano() })
			wake = time.After(time.Until(next.at))
		}
		select {
		case <-wake:
			err = e.fire(next)
			if _, isException := errors.AsType[*jsc.Exception](err); isException {
				current.fail("in a timer: " + err.Error())
				err = nil
			}
		case event := <-e.events:
			for len(e.events) > 0 {
				event = <-e.events
			}
			err = e.dispatchEvent(event)
		case <-current.ctx.Done():
			current.fail(current.stopped().Error())
			return
		}
	}
	switch {
	case errors.Is(err, jsc.ErrTerminated):
		current.fail(current.stopped().Error())
		return
	case err != nil:
		current.fail(err.Error())
		return
	case current.ctx.Err() != nil:
		current.fail(current.stopped().Error())
	}
	var pending []string
	if count := len(e.timers); count > 0 {
		pending = append(pending, counted(count, "timer"))
	}
	if count := len(e.subscriptions); count > 0 {
		pending = append(pending, counted(count, "listener"))
	}
	if len(pending) > 0 {
		verb := "were"
		if len(e.timers)+len(e.subscriptions) == 1 {
			verb = "was"
		}
		current.write("[" + strings.Join(pending, " and ") + " " + verb + " still pending when the script finished and " + verb + " cancelled]")
	}
}

func counted(count int, noun string) string {
	if count == 1 {
		return "1 " + noun
	}
	return strconv.Itoa(count) + " " + noun + "s"
}

func (e *engine) input(code string) (jsc.Value, error) {
	input := e.context.NewString(code)
	source, err := e.call(e.rewrite, input)
	input.Release()
	if err != nil {
		return jsc.Value{}, err
	}
	return e.context.Evaluate(source, "input.js")
}

func (e *engine) start(current *run, script func() (jsc.Value, error)) error {
	function, err := script()
	if err != nil {
		return err
	}
	defer function.Release()
	fulfilled := e.context.NewFunction(func(arguments []jsc.Value) (any, error) {
		current.settled = true
		if current.nested {
			value, err := arguments[0].JSON()
			if err != nil {
				current.fail("the default export of " + EntryFile + " does not pass through JSON: " + err.Error())
				return nil, nil
			}
			current.value = value
			return nil, nil
		}
		text, err := e.call(e.outcome, arguments[0])
		if err != nil {
			current.fail(err.Error())
			return nil, nil
		}
		if text != "" {
			current.write(text)
		}
		return nil, nil
	})
	defer fulfilled.Release()
	rejected := e.context.NewFunction(func(arguments []jsc.Value) (any, error) {
		current.settled = true
		current.fail(arguments[0].Describe())
		return nil, nil
	})
	defer rejected.Release()
	result, err := e.launch.Call(function, fulfilled, rejected)
	if err != nil {
		return err
	}
	result.Release()
	return nil
}

func (e *engine) fire(next *timer) error {
	if next.interval {
		next.at = time.Now().Add(next.delay)
	} else {
		e.timers = slices.DeleteFunc(e.timers, func(it *timer) bool { return it == next })
		defer next.release()
	}
	result, err := next.callback.Call(next.arguments...)
	if err != nil {
		return err
	}
	result.Release()
	return nil
}

func (e *engine) call(function jsc.Value, arguments ...jsc.Value) (string, error) {
	result, err := function.Call(arguments...)
	if err != nil {
		return "", err
	}
	defer result.Release()
	return result.ToString()
}

func (e *engine) print(arguments []jsc.Value) (any, error) {
	text, err := e.call(e.format, arguments...)
	if err != nil {
		return nil, err
	}
	if e.run.logger != nil {
		e.run.logger.Info(text)
		return nil, nil
	}
	e.run.write(text)
	return nil, nil
}

func (e *engine) schedule(interval bool) jsc.Function {
	return func(arguments []jsc.Value) (any, error) {
		if len(arguments) == 0 || !arguments[0].IsFunction() {
			return nil, E.New("the callback is not a function")
		}
		delay := time.Millisecond
		if len(arguments) > 1 {
			if ms := arguments[1].Number(); ms >= 1 && ms <= math.MaxInt32 {
				delay = time.Duration(ms * float64(time.Millisecond))
			}
		}
		rest := arguments[min(len(arguments), 2):]
		arguments[0].Protect()
		for _, argument := range rest {
			argument.Protect()
		}
		e.sequence++
		e.timers = append(e.timers, &timer{
			id:        e.sequence,
			at:        time.Now().Add(delay),
			delay:     delay,
			interval:  interval,
			callback:  arguments[0],
			arguments: rest,
		})
		return e.sequence, nil
	}
}

func (e *engine) clear(arguments []jsc.Value) (any, error) {
	if len(arguments) == 0 {
		return nil, nil
	}
	id := arguments[0].Number()
	index := slices.IndexFunc(e.timers, func(it *timer) bool { return float64(it.id) == id })
	if index >= 0 {
		e.timers[index].release()
		e.timers = slices.Delete(e.timers, index, index+1)
	}
	return nil, nil
}

func (e *engine) operation(s *Runner, name string) jsc.Function {
	return func(arguments []jsc.Value) (any, error) {
		current := e.run
		if current.ctx.Err() != nil {
			return nil, current.stopped()
		}
		if err := e.giveWay(current.ctx); err != nil {
			return nil, err
		}
		args := make([]json.RawMessage, len(arguments))
		for index, argument := range arguments {
			data, err := argument.JSON()
			if err != nil {
				return nil, E.Cause(err, "encode argument ", index+1)
			}
			if data == "" {
				data = "null"
			}
			args[index] = json.RawMessage(data)
		}
		value, err := s.dispatch(current, e.elements, name, args)
		if err != nil && current.ctx.Err() != nil {
			if E.IsCanceled(err) {
				return nil, current.stopped()
			}
			return nil, E.Cause(err, current.stopped().Error())
		}
		return value, err
	}
}

func (s *Runner) execute(ctx context.Context, timeout time.Duration, exclusive bool, body func(current *run)) *run {
	parent := s.ctx
	if exclusive {
		s.access.Lock()
		parent = s.epoch
		s.access.Unlock()
	}
	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)
	defer context.AfterFunc(parent, func() { cancel(context.Cause(parent)) })()
	if timeout > 0 {
		var cancelTimeout context.CancelFunc
		ctx, cancelTimeout = context.WithTimeout(ctx, timeout)
		defer cancelTimeout()
	}
	current := &run{transcript: &transcript{}, ctx: ctx, stop: cancel, timeout: timeout}
	if exclusive {
		if err := s.lock(ctx); err != nil {
			if errors.Is(err, context.DeadlineExceeded) {
				current.fail("another call ran for the whole time limit of " + timeout.String())
			} else {
				current.fail(current.stopped().Error())
			}
			return current
		}
		defer s.unlock()
	}
	body(current)
	return current
}

func (s *Runner) session(current *run, code string) {
	if s.engine == nil {
		engine, err := s.newEngine("", s.elements)
		if err != nil {
			current.fail("start JavaScript: " + err.Error())
			return
		}
		s.engine = engine
	}
	s.engine.execute(current, func() (jsc.Value, error) { return s.engine.input(code) })
}
