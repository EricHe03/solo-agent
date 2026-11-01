//go:build darwin && cgo

package automation

import (
	"context"
	"encoding/json"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/jsc"
)

type Graphics interface {
	Entry() uintptr
	Run(engine uint64, call int64, context *GraphicsCall) (json.RawMessage, error)
	Watch(engine uint64, call int64, context *GraphicsCall, publish func(any)) error
}

const (
	graphicsInstall int32 = iota
	graphicsUninstall
)

const timelineLimit = 100_000

var (
	errNoGraphics   = E.New("graphics: this platform has no graphics")
	errScreenEnded  = E.New("graphics: the screen stream ended")
	graphicsEngines atomic.Uint64
)

var timelineOperations = []string{
	"device.unlock", "device.launchApplication", "input.tap", "input.swipe", "input.drag", "input.pinch", "input.touch", "input.pressKey",
	"input.button", "accessibility.setText", "accessibility.perform",
}

type GraphicsCall struct {
	ctx  context.Context
	call *operation
}

func (c *GraphicsCall) Context() context.Context {
	return c.ctx
}

func (c *GraphicsCall) Screenshot() ([]byte, float64, error) {
	phone, err := c.call.screen(c.ctx)
	if err != nil {
		return nil, 0, err
	}
	return phone.Capture(c.ctx)
}

func (c *GraphicsCall) WatchTimeline() *TimelineWatch {
	return c.call.engine.host.watchTimeline()
}

func (e *engine) installGraphics(native jsc.Value) {
	graphics := e.host.options.Graphics
	if graphics == nil {
		return
	}
	e.graphics = graphicsEngines.Add(1)
	e.context.RunNative(graphics.Entry(), graphicsInstall, native, e.graphics)
}

func (e *engine) uninstallGraphics() {
	graphics := e.host.options.Graphics
	if graphics == nil || e.graphics == 0 {
		return
	}
	e.context.RunNative(graphics.Entry(), graphicsUninstall, jsc.Value{}, e.graphics)
	e.graphics = 0
}

func graphicsRun(ctx context.Context, call *operation) (any, error) {
	var id int64
	if err := call.decode(1, &id); err != nil {
		return nil, err
	}
	graphics := call.engine.host.options.Graphics
	if graphics == nil {
		return nil, errNoGraphics
	}
	return graphics.Run(call.engine.graphics, id, &GraphicsCall{ctx: ctx, call: call})
}

func (e *engine) watchGraphics(ctx context.Context, call *operation, publish func(any, error), ended func(error)) error {
	var id int64
	if err := call.decode(1, &id); err != nil {
		return err
	}
	graphics := e.host.options.Graphics
	if graphics == nil {
		return errNoGraphics
	}
	go func() {
		err := graphics.Watch(e.graphics, id, &GraphicsCall{ctx: ctx, call: call}, func(value any) { publish(value, nil) })
		if err == nil {
			err = errScreenEnded
		}
		ended(err)
	}()
	return nil
}

type TimelineEvent struct {
	Time       int64             `json:"time"`
	Type       string            `json:"type"`
	Name       string            `json:"name,omitempty"`
	Arguments  []json.RawMessage `json:"arguments,omitempty"`
	DurationMs float64           `json:"durationMs,omitempty"`
	Error      string            `json:"error,omitempty"`
	Swiplet    string            `json:"swiplet,omitempty"`
	Action     string            `json:"action,omitempty"`
	Caller     string            `json:"caller,omitempty"`
	App        string            `json:"app,omitempty"`
	Level      string            `json:"level,omitempty"`
	Message    string            `json:"message,omitempty"`
}

type timeline struct {
	access  sync.Mutex
	watches map[*TimelineWatch]struct{}
}

type TimelineWatch struct {
	timeline *timeline
	cancel   context.CancelFunc
	done     chan struct{}
	access   sync.Mutex
	events   []TimelineEvent
}

func (t *timeline) record(event TimelineEvent) {
	t.access.Lock()
	defer t.access.Unlock()
	for watch := range t.watches {
		watch.add(event)
	}
}

func (t *timeline) active() bool {
	t.access.Lock()
	defer t.access.Unlock()
	return len(t.watches) > 0
}

func (h *Host) watchTimeline() *TimelineWatch {
	ctx, cancel := context.WithCancel(h.ctx)
	watch := &TimelineWatch{timeline: &h.timeline, cancel: cancel, done: make(chan struct{})}
	h.timeline.access.Lock()
	h.timeline.watches[watch] = struct{}{}
	h.timeline.access.Unlock()
	go func() {
		defer close(watch.done)
		if phone := h.options.Device; phone != nil {
			_ = phone.WatchForeground(ctx, func(app string) {
				watch.add(TimelineEvent{Time: time.Now().UnixMilli(), Type: "foreground", App: app})
			})
		}
	}()
	return watch
}

func (w *TimelineWatch) add(event TimelineEvent) {
	w.access.Lock()
	defer w.access.Unlock()
	if len(w.events) < timelineLimit {
		w.events = append(w.events, event)
	}
}

func (w *TimelineWatch) Stop() []TimelineEvent {
	w.timeline.access.Lock()
	delete(w.timeline.watches, w)
	w.timeline.access.Unlock()
	w.cancel()
	<-w.done
	w.access.Lock()
	defer w.access.Unlock()
	events := slices.Clone(w.events)
	common.SortBy(events, func(it TimelineEvent) int64 { return it.Time })
	return events
}
