package device

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"math"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice/accessibility"
	"github.com/swipt-automation/swipt/internal/coredevice/apps"
	"github.com/swipt-automation/swipt/internal/coredevice/hid"
)

// A test app came to the front 122 to 138 ms after a warm launch request and
// 662 to 1,042 ms after a cold one, and Clock 1.71 s after a cold one
// (iPhone18,2, iOS 27.2 24B115).
const launchLimit = 3500 * time.Millisecond

// A text field takes the focus as the tap's touch-up is handled, and the
// device reports the change within 150 ms (iPad17,1, iPadOS 27.2 24B115).
const focusLimit = 500 * time.Millisecond

const settleLimit = 3 * time.Second

var (
	errExpired = E.New("the wait expired")
	errLeft    = E.New("the app left the front")
)

type pendingError struct {
	message string
	gone    bool
	retry   bool
}

func (e *pendingError) Error() string {
	return e.message
}

type ElementAction struct {
	Kind  string
	Count int
	Hold  time.Duration
	Text  string
	Name  string
	Each  bool
}

type query struct {
	selectors []*Selector
	each      bool
	options   accessibility.ApplicationOptions
	apps      []string
	anyApp    bool
	keys      map[bool]string
}

func newQuery(selectors []*Selector, act ElementAction) (*query, error) {
	if len(selectors) == 0 {
		return nil, E.Extend(ErrInvalid, "a locator needs a selector")
	}
	q := &query{selectors: selectors, each: act.Each}
	var fields []string
	for _, selector := range selectors {
		if selector.Scripted() {
			return nil, E.Extend(ErrInvalid, selector.String(), " holds a function or a regular expression only JavaScript can run, which a locator cannot")
		}
		if selector.References() {
			return nil, E.Extend(ErrInvalid, selector.String(), " refers to an element of a snapshot, which a locator cannot")
		}
		fields = append(fields, selector.Fields()...)
		switch app := selector.App(); app {
		case springboardBundleID:
		case "":
			q.anyApp = true
		default:
			q.apps = append(q.apps, app)
		}
	}
	switch act.Kind {
	case "tap", "setText":
	case "perform":
		if _, standard := phoneActions[act.Name]; !standard {
			fields = append(fields, "actions")
		}
	default:
		return nil, E.Extend(ErrInvalid, "unknown element action ", strconv.Quote(act.Kind))
	}
	q.options = accessibility.ApplicationOptions{
		Attributes: accessibility.SnapshotAttributes(fields),
		Modal:      slices.Contains(fields, "inert"),
		Focused:    slices.Contains(fields, "focused"),
	}
	q.keys = make(map[bool]string)
	for _, system := range []bool{false, true} {
		q.keys[system] = fmt.Sprint("query:", system, ":", q.options.Modal, ":", q.options.Focused, ":", q.options.Attributes)
	}
	return q, nil
}

func (q *query) String() string {
	return strings.Join(common.Map(q.selectors, (*Selector).String), " or ")
}

func (q *query) match(read func(system bool) (*PhoneModel, error)) ([]*PhoneNode, error) {
	views := make(map[bool]*View)
	var found []*PhoneNode
	for _, selector := range q.selectors {
		system := selector.App() == springboardBundleID
		view, known := views[system]
		if !known {
			model, err := read(system)
			if err != nil {
				return nil, err
			}
			if model != nil {
				view = NewView(model, true)
			}
			views[system] = view
		}
		if view == nil {
			continue
		}
		if !q.each {
			element, err := view.Find("", selector, nil)
			if err != nil {
				return nil, err
			}
			if element != nil {
				return []*PhoneNode{element.node}, nil
			}
			continue
		}
		elements, err := view.FindAll("", selector, nil)
		if err != nil {
			return nil, err
		}
		for _, element := range elements {
			if !slices.Contains(found, element.node) {
				found = append(found, element.node)
			}
		}
	}
	return found, nil
}

func (p *Phone) readApplication(ctx context.Context, c *conn, client *accessibility.RemoteClient, geometry phoneGeometry, options accessibility.ApplicationOptions) (*PhoneModel, error) {
	started := time.Now()
	screen, err := client.ReadApplication(ctx, options)
	if err != nil {
		if options.PID != 0 && errors.Is(err, accessibility.ErrNoAnswer) {
			c.springboard.CompareAndSwap(options.PID, 0)
		}
		return nil, err
	}
	return p.model(c, geometry, screen, started, options.PID == 0), nil
}

func (p *Phone) find(ctx context.Context, c *conn, q *query) ([]*PhoneNode, frontApplication, error) {
	geometry, err := c.readGeometry(ctx)
	if err != nil {
		return nil, frontApplication{}, err
	}
	var front frontApplication
	nodes, err := q.match(func(system bool) (*PhoneModel, error) {
		options, key := q.options, q.keys[system]
		if system {
			pid, err := c.springboardPID(ctx)
			if err != nil {
				return nil, err
			}
			options.PID = pid
		} else if !q.anyApp {
			app, err := c.front.get(ctx)
			if err != nil {
				return nil, err
			}
			if front = app; !slices.Contains(q.apps, front.bundleID) {
				return nil, nil
			}
			options.PID = app.pid
			key += ":" + strconv.FormatUint(app.pid, 10)
		}
		value, err := c.ax.read(ctx, key, func(ctx context.Context, client *accessibility.RemoteClient) (any, error) {
			return p.readApplication(ctx, c, client, geometry, options)
		})
		if err != nil {
			return nil, err
		}
		model := value.(*PhoneModel)
		if !system {
			front = frontApplication{pid: model.Root.AX.Ref.PID, bundleID: model.BundleID}
		}
		return model, nil
	})
	return nodes, front, err
}

type locateState struct {
	reason   string
	revealed map[accessibility.ElementRef]bool
	app      string
	tapped   map[accessibility.ElementRef]bool
}

func (p *Phone) Locate(ctx context.Context, selectors []*Selector, act ElementAction, timeout time.Duration) error {
	q, err := newQuery(selectors, act)
	if err != nil {
		return err
	}
	waiting := ctx
	var deadline time.Time
	if timeout >= 0 {
		deadline = time.Now().Add(timeout)
		var cancel context.CancelFunc
		waiting, cancel = context.WithDeadline(ctx, deadline)
		defer cancel()
	}
	state := &locateState{
		reason: "the device did not connect", revealed: make(map[accessibility.ElementRef]bool), tapped: make(map[accessibility.ElementRef]bool),
	}
	for {
		c, release, err := p.connection.acquire(waiting)
		if err == nil {
			operation, cancel := c.operation(ctx)
			if q.each {
				err = p.watch(operation, c, q, act, state)
			} else {
				err = p.locate(operation, c, q, act, deadline, state)
			}
			cancel()
			release()
		}
		switch {
		case err == nil:
			return nil
		case ctx.Err() != nil:
			return ctx.Err()
		case errors.Is(err, errExpired), waiting.Err() != nil:
			return E.Extend(ErrTimeout, state.reason, "; gave up after ", timeout)
		case c != nil && c.ctx.Err() != nil:
		default:
			return err
		}
	}
}

func (p *Phone) locate(ctx context.Context, c *conn, q *query, act ElementAction, deadline time.Time, state *locateState) error {
	changed, stop := c.events.watch(true)
	defer stop()
	if !q.anyApp {
		defer c.front.watch(func(ForegroundApp) {})()
	}
	var expire <-chan time.Time
	if !deadline.IsZero() {
		timer := time.NewTimer(time.Until(deadline))
		defer timer.Stop()
		expire = timer.C
	}
	var delay time.Duration
	for {
		seen := c.events.screen.Load()
		nodes, front, err := p.find(ctx, c, q)
		retry := false
		switch {
		case err == nil && len(nodes) == 0:
			state.reason = "nothing matched " + q.String()
			if front.bundleID != "" {
				state.reason += "; " + front.bundleID + " is in front"
			}
		case err == nil:
			err = p.attempt(ctx, c, q, act, nodes[0], front.pid, seen, state)
			pending, isPending := errors.AsType[*pendingError](err)
			switch {
			case err == nil:
				return nil
			case !isPending:
				return err
			}
			state.reason, retry = pending.message, pending.retry
		case transient(err), errors.Is(err, ErrStalled):
			state.reason, retry = err.Error(), true
		default:
			return err
		}
		var again <-chan time.Time
		var timer *time.Timer
		if retry {
			delay = min(max(delay*2, pollFirst), pollLongest)
			timer = time.NewTimer(delay)
			again = timer.C
		} else {
			delay = 0
		}
		var ended error
		select {
		case <-changed:
		case <-again:
		case <-expire:
			ended = errExpired
		case <-ctx.Done():
			ended = ctx.Err()
		}
		if timer != nil {
			timer.Stop()
		}
		if ended != nil {
			return ended
		}
	}
}

func (p *Phone) watch(ctx context.Context, c *conn, q *query, act ElementAction, state *locateState) error {
	changed, stop := c.events.watch(true)
	defer stop()
	defer c.front.watch(func(ForegroundApp) {})()
	quiet := time.Now().Add(settleLimit)
	var delay time.Duration
	for {
		retry, err := p.tapNew(ctx, c, q, act, state)
		switch {
		case errors.Is(err, errLeft):
			return nil
		case err == nil:
		case transient(err), errors.Is(err, ErrStalled):
			retry = true
		default:
			return err
		}
		var again <-chan time.Time
		var timer *time.Timer
		if retry && time.Now().Before(quiet) {
			delay = min(max(delay*2, pollFirst), pollLongest)
			timer = time.NewTimer(min(delay, time.Until(quiet)))
			again = timer.C
		} else {
			delay = 0
		}
		select {
		case <-changed:
			quiet = time.Now().Add(settleLimit)
		case <-again:
		case <-ctx.Done():
		}
		if timer != nil {
			timer.Stop()
		}
		if err = ctx.Err(); err != nil {
			return err
		}
	}
}

func (p *Phone) tapNew(ctx context.Context, c *conn, q *query, act ElementAction, state *locateState) (bool, error) {
	seen := c.events.screen.Load()
	front, err := c.front.get(ctx)
	if err != nil {
		return false, err
	}
	if state.app == "" {
		state.app = front.bundleID
		if len(q.apps) > 0 && !q.anyApp && !slices.Contains(q.apps, state.app) {
			return false, errLeft
		}
	}
	if front.bundleID != state.app {
		return false, errLeft
	}
	nodes, read, err := p.find(ctx, c, q)
	if err != nil {
		return false, err
	}
	if read.bundleID != "" && read.bundleID != state.app {
		return false, errLeft
	}
	present := make(map[accessibility.ElementRef]bool, len(nodes))
	for _, node := range nodes {
		present[node.AX.Ref] = true
	}
	maps.DeleteFunc(state.tapped, func(ref accessibility.ElementRef, _ bool) bool { return !present[ref] })
	retry := false
	for _, node := range nodes {
		switch {
		case state.tapped[node.AX.Ref]:
			continue
		case slices.ContainsFunc(nodes, func(other *PhoneNode) bool {
			return state.tapped[other.AX.Ref] && (other.Contains(node) || node.Contains(other))
		}):
			state.tapped[node.AX.Ref] = true
			continue
		case !node.Shown() || node.Covered:
			continue
		}
		err = p.attempt(ctx, c, q, act, node, read.pid, seen, state)
		if err == nil {
			state.tapped[node.AX.Ref] = true
			return retry, nil
		}
		pending, isPending := errors.AsType[*pendingError](err)
		if !isPending {
			return retry, err
		}
		retry = retry || pending.retry
	}
	return retry, nil
}

func (p *Phone) attempt(ctx context.Context, c *conn, q *query, act ElementAction, found *PhoneNode, app, seen uint64, state *locateState) error {
	geometry, err := c.readGeometry(ctx)
	if err != nil {
		return err
	}
	grant, err := p.connection.input.acquire(ctx, c)
	if err != nil {
		return err
	}
	defer grant.release()
	s := &axSession{phone: p, conn: c, geometry: geometry, grant: grant, revealed: state.revealed}
	err = c.ax.do(ctx, true, 0, func(ctx context.Context, client *accessibility.RemoteClient) error {
		s.client = client
		target := found
		if c.events.screen.Load() != seen || found.model.generation != c.ax.current() {
			nodes, err := q.match(func(system bool) (*PhoneModel, error) {
				options := q.options
				if system {
					pid, err := c.springboardPID(ctx)
					if err != nil {
						return nil, err
					}
					options.PID = pid
				} else if !q.anyApp {
					options.PID = app
				}
				return p.readApplication(ctx, c, client, geometry, options)
			})
			if err != nil {
				return err
			}
			target = common.Find(nodes, func(node *PhoneNode) bool { return !q.each || node.AX.Ref == found.AX.Ref })
			if target == nil {
				return &pendingError{message: "nothing matched " + q.String()}
			}
			if q.each && (!target.Shown() || target.Covered) {
				return &pendingError{message: describeElement(target.AX) + " left the screen"}
			}
		}
		switch act.Kind {
		case "tap":
			at, err := s.aim(ctx, target)
			if err != nil {
				return err
			}
			return s.tap(ctx, at, act.Count, act.Hold)
		case "setText":
			return s.setText(ctx, target, act.Text)
		}
		return s.perform(ctx, target, act.Name)
	})
	if s.acted {
		c.events.publish(Event{Kind: EventInput})
		c.front.acted()
	} else if errors.Is(err, ErrStalled) {
		return &pendingError{message: err.Error(), retry: true}
	}
	return err
}

func (p *Phone) TapElement(ctx context.Context, ref string, count int, hold time.Duration) error {
	parsed, err := parseRef(ref)
	if err != nil {
		return err
	}
	c, ctx, done, err := p.begin(ctx)
	if err != nil {
		return err
	}
	defer done()
	if err = p.requireScreen(ctx, c); err != nil {
		return err
	}
	geometry, err := c.readGeometry(ctx)
	if err != nil {
		return err
	}
	springboard, err := c.springboardPID(ctx)
	if err != nil {
		return err
	}
	grant, err := p.connection.input.acquire(ctx, c)
	if err != nil {
		return err
	}
	defer grant.release()
	s := &axSession{phone: p, conn: c, geometry: geometry, grant: grant, revealed: make(map[accessibility.ElementRef]bool)}
	err = c.ax.do(ctx, true, 0, func(ctx context.Context, client *accessibility.RemoteClient) error {
		s.client = client
		node := c.nodes.find(parsed, c.ax.current())
		deadline := time.Now().Add(settleLimit)
		var delay time.Duration
		for {
			if node == nil {
				model, err := p.readScreen(ctx, c, client, geometry, springboard, SnapshotOptions{})
				if err != nil {
					return err
				}
				if node = model.Node(parsed); node == nil {
					return E.Extend(ErrNotFound, "the element is no longer on the screen; ", model.BundleID, " is in front")
				}
			}
			at, err := s.aim(ctx, node)
			if err == nil {
				return s.tap(ctx, at, count, hold)
			}
			pending, isPending := errors.AsType[*pendingError](err)
			if !isPending || !pending.retry || time.Now().After(deadline) {
				return err
			}
			delay = min(max(delay*2, pollFirst), pollLongest)
			if err = sleep(ctx, delay); err != nil {
				return err
			}
			node = nil
		}
	})
	if s.acted {
		c.events.publish(Event{Kind: EventInput})
		c.front.acted()
	}
	if pending, isPending := errors.AsType[*pendingError](err); isPending {
		if pending.gone {
			return E.Extend(ErrNotFound, pending.message)
		}
		return E.New(pending.message)
	}
	return err
}

type axSession struct {
	phone    *Phone
	conn     *conn
	client   *accessibility.RemoteClient
	geometry phoneGeometry
	grant    *hidGrant
	revealed map[accessibility.ElementRef]bool
	acted    bool
}

func (s *axSession) tap(ctx context.Context, at Point, count int, hold time.Duration) error {
	s.acted = true
	return s.grant.send(func(input *hid.Client) error {
		return tap(ctx, s.geometry, input, at, count, hold)
	})
}

func (s *axSession) aim(ctx context.Context, target *PhoneNode) (Point, error) {
	name := describeElement(target.AX)
	switch {
	case !target.HasFrame():
		return Point{}, E.New(name, " has no position on the screen; perform one of its actions instead")
	case !target.AX.Enabled:
		return Point{}, &pendingError{message: name + " is disabled", retry: true}
	case !target.Shown() || target.Covered:
		return Point{}, s.reveal(ctx, target)
	}
	at := target.Point
	for attempt := 0; ; attempt++ {
		batch := &accessibility.Batch{}
		mapped := batch.Mapped(target.AX)
		attributes := batch.Attributes(target.AX)
		hit := batch.HitTest(s.geometry.digitizer(at))
		if err := s.client.Run(ctx, batch); err != nil {
			return Point{}, err
		}
		switch {
		case mapped.Code == 0 && !mapped.Value:
			return Point{}, &pendingError{message: name + " is gone", gone: true, retry: true}
		case mapped.Code != 0 || attributes.Code != 0:
			return Point{}, &pendingError{message: name + " did not answer", gone: true, retry: true}
		case !attributes.Value.Enabled:
			return Point{}, &pendingError{message: name + " is disabled", retry: true}
		case !equalFrame(attributes.Value.Frame, target.AX.Frame):
			return Point{}, &pendingError{message: name + " is moving", retry: true}
		case hit.Code != 0:
			return Point{}, &pendingError{message: "the device does not tell which element is at " + pointText(at), retry: true}
		}
		node := target.model.Node(hit.Value.Ref)
		if hit.Value.Ref == target.AX.Ref || node != nil && target.Contains(node) {
			return at, nil
		}
		read := &accessibility.Batch{}
		element := read.Attributes(hit.Value)
		if err := s.client.Run(ctx, read); err != nil {
			return Point{}, err
		}
		if element.Code == 0 && (lands(target, element.Value) || sameWindow(target, element.Value)) {
			return at, nil
		}
		if attempt == 0 && node != nil && node.Shown() {
			if piece := common.MaxBy(target.Visible.subtract(node.Visible), Rect.area); piece.area() > 0 {
				at = piece.Center()
				continue
			}
		}
		if target.Inert {
			return Point{}, &pendingError{message: name + " is behind a modal view, as a sheet or an alert", retry: true}
		}
		return Point{}, &pendingError{message: "a tap at " + pointText(at) + " would reach " + describeElement(element.Value) + ", not " + name, retry: true}
	}
}

func lands(target *PhoneNode, hit accessibility.Element) bool {
	node := target.model.Node(hit.Ref)
	return hit.Ref == target.AX.Ref || node != nil && (target.Contains(node) || hit.AccessibilityElement && node.Contains(target)) ||
		node == nil && within(target.AX.Frame, hit.Frame)
}

// Within the window on top, the hit test answered the status bar view of
// Damai's navigation bar, listed before the launch ad's skip button over it,
// where a touch reached the button (iPhone18,2, iOS 27.2 24B115).
func sameWindow(target *PhoneNode, hit accessibility.Element) bool {
	context := hit.Context
	if node := target.model.Node(hit.Ref); node != nil {
		context = node.context()
	}
	if own := target.context(); context != 0 && own != 0 {
		return context == own
	}
	return hit.Ref.PID == target.AX.Ref.PID
}

func equalFrame(first, second *accessibility.LayoutFrame) bool {
	return first == nil && second == nil || first != nil && second != nil && *first == *second
}

// UIKit answers a page scroll action with the content offset still animating
// (24B5110a UIKit.axbundle 0x189ff2200, 0x189ff2ea4), and the translator folds
// the page-scrolled notification into a later tree push instead of forwarding
// it (24B5110a AccessibilityPlatformTranslation 0x253fe623c); a tap on a list
// still scrolling only stops it, while web content can answer its old frame
// twice (iPhone18,2, iOS 27.2 24B115).
func (s *axSession) reveal(ctx context.Context, target *PhoneNode) error {
	name := describeElement(target.AX)
	state := "off screen"
	if target.Covered {
		state = "covered by the keyboard or a banner"
	}
	if s.revealed[target.AX.Ref] {
		return &pendingError{message: name + " stayed " + state + " after scrolling it into view"}
	}
	s.revealed[target.AX.Ref] = true
	batch := &accessibility.Batch{}
	perform := batch.Perform(target.AX, accessibility.ActionScrollToVisible)
	s.acted = true
	if err := s.client.Run(ctx, batch); err != nil {
		return err
	}
	if err := perform.Err("scroll the element into view"); err != nil {
		return err
	}
	if !perform.Value {
		return &pendingError{message: name + " is " + state + ", and its scroll view refused to scroll it into view"}
	}
	return &pendingError{message: "scrolled " + name + " into view", retry: true}
}

// The keyboard's candidate bar lists each candidate as an element the
// snapshot shows, while the hit test answers the label inside it, which the
// snapshot does not (iPhone18,2, iOS 27.2 24B115).
func within(outer, inner *accessibility.LayoutFrame) bool {
	return outer != nil && inner != nil && inner.X >= outer.X-1 && inner.Y >= outer.Y-1 &&
		inner.X+inner.Width <= outer.X+outer.Width+1 && inner.Y+inner.Height <= outer.Y+outer.Height+1
}

func pointText(at Point) string {
	return "[" + strconv.FormatFloat(math.Round(at.X*10)/10, 'f', -1, 64) + ", " + strconv.FormatFloat(math.Round(at.Y*10)/10, 'f', -1, 64) + "]"
}

func describeElement(element accessibility.Element) string {
	switch {
	case element.Label != "":
		return "the element " + strconv.Quote(PlainText(element.Label))
	case element.Identifier != "":
		return "the element with the identifier " + strconv.Quote(element.Identifier)
	case element.Value != "":
		return "the element valued " + strconv.Quote(PlainText(element.Value))
	case element.Class != "":
		return "an unlabeled " + element.Class
	}
	return "an unlabeled element"
}

var phoneActions = map[string]uint64{
	"press": accessibility.ActionPress, "increment": accessibility.ActionIncrement, "decrement": accessibility.ActionDecrement,
	"escape": accessibility.ActionEscape, "menu": accessibility.ActionShowContextMenu,
	"scrollUp": accessibility.ActionScrollUpByPage, "scrollDown": accessibility.ActionScrollDownByPage,
	"scrollLeft": accessibility.ActionScrollLeftByPage, "scrollRight": accessibility.ActionScrollRightByPage,
	"scrollToVisible": accessibility.ActionScrollToVisible,
}

func (s *axSession) perform(ctx context.Context, target *PhoneNode, name string) error {
	number, standard := phoneActions[name]
	custom := common.Find(target.AX.Actions, func(candidate accessibility.CustomAction) bool { return candidate.Name == name })
	if !standard && custom.Identifier == "" {
		names := append(slices.Sorted(maps.Keys(phoneActions)), common.Map(target.AX.Actions, func(it accessibility.CustomAction) string { return it.Name })...)
		return E.Extend(ErrInvalid, describeElement(target.AX), " has no action ", strconv.Quote(name), "; its actions are ", strings.Join(names, ", "))
	}
	if !target.AX.Enabled {
		return &pendingError{message: describeElement(target.AX) + " is disabled", retry: true}
	}
	batch := &accessibility.Batch{}
	mapped := batch.Mapped(target.AX)
	var perform *accessibility.Result[bool]
	if standard {
		perform = batch.Perform(target.AX, number)
	} else {
		perform = batch.PerformCustom(target.AX, custom)
	}
	s.acted = true
	if err := s.client.Run(ctx, batch); err != nil {
		return err
	}
	if err := mapped.Err("check the element"); err != nil {
		return err
	}
	if !mapped.Value {
		return &pendingError{message: describeElement(target.AX) + " is gone", gone: true, retry: true}
	}
	if err := perform.Err("perform " + strconv.Quote(name)); err != nil {
		return err
	}
	if !perform.Value {
		return E.New(describeElement(target.AX), " refused to perform ", strconv.Quote(name))
	}
	return nil
}

// A backspace from the keyboard changed Claude's chat input 177 to 518 ms after
// it was sent (iPhone18,2, iOS 27.2 24B115).
const keyLimit = 2 * time.Second

func (s *axSession) setText(ctx context.Context, target *PhoneNode, text string) error {
	if !target.AX.TextInput() {
		return E.New(describeElement(target.AX), " is not a text entry")
	}
	entry, err := s.focus(ctx, target)
	if err != nil {
		return err
	}
	// UIKit sets a text view's value with setText: and keyboardInputChanged:
	// alone, which Claude's chat input did not take as an edit, while a text
	// field's setter sends fieldEditorDidChange: and a focused web entry
	// inserts the text through its editor (24B5110a UIKit.axbundle
	// 0x18a052c34, 0x18a047f50; 24B5110a UIKitCore 0x185cffcc4; WebKit
	// f98a24d3, Source/WebCore/accessibility/AccessibilityRenderObject.cpp:1886;
	// iPhone18,2, iOS 27.2 24B115). Deleting a trailing space with the keyboard
	// made it one.
	nudge := entry.AX.TextView() && !entry.Web
	value := text
	if nudge {
		value += " "
	}
	batch := &accessibility.Batch{}
	set := batch.SetValue(entry.AX, value)
	s.acted = true
	if err = s.client.Run(ctx, batch); err != nil {
		return err
	}
	if err = set.Err("set the text"); err != nil {
		return err
	}
	if !nudge {
		return s.checkText(ctx, entry, text)
	}
	err = s.grant.send(func(input *hid.Client) error {
		return pressKeys(ctx, input, []uint8{usageBackspace})
	})
	if err != nil {
		return err
	}
	var last error
	matched, err := s.conn.wait(ctx, time.Now().Add(keyLimit), func(ctx context.Context) (bool, error) {
		last = s.checkText(ctx, entry, text)
		return last == nil, nil
	})
	if err == nil && !matched {
		err = last
	}
	return err
}

// Tapping a text field can bring another entry in its place, as Safari's
// address bar gives way to its editing field (iPhone18,2, iOS 27.2 24B115).
func (s *axSession) focus(ctx context.Context, target *PhoneNode) (*PhoneNode, error) {
	app := target.model.Root.AX
	before, err := s.focused(ctx, app)
	if err != nil {
		return nil, err
	}
	if before != nil && *before == target.AX.Ref {
		return target, nil
	}
	at, err := s.aim(ctx, target)
	if err != nil {
		return nil, err
	}
	if err = s.tap(ctx, at, 1, 0); err != nil {
		return nil, err
	}
	var focused *accessibility.ElementRef
	changed, err := s.conn.wait(ctx, time.Now().Add(focusLimit), func(ctx context.Context) (bool, error) {
		var err error
		focused, err = s.focused(ctx, app)
		return focused != nil && (before == nil || *focused != *before), err
	})
	if err != nil {
		return nil, err
	}
	if !changed {
		if before != nil {
			held := "another element"
			if node := target.model.Node(*before); node != nil {
				held = describeElement(node.AX)
			}
			return nil, E.New("tapping ", describeElement(target.AX), " left the keyboard focus on ", held)
		}
		return nil, E.New("tapping ", describeElement(target.AX), " did not focus a text entry")
	}
	if *focused == target.AX.Ref {
		return target, nil
	}
	model, err := s.phone.readApplication(ctx, s.conn, s.client, s.geometry, accessibility.ApplicationOptions{
		PID: app.Ref.PID, Attributes: accessibility.SnapshotAttributes([]string{"label", "identifier", "value"}),
	})
	if err != nil {
		return nil, err
	}
	node := model.Node(*focused)
	if node == nil {
		return nil, E.New("tapping ", describeElement(target.AX), " focused an element the screen does not list")
	}
	return node, nil
}

func (s *axSession) focused(ctx context.Context, app accessibility.Element) (*accessibility.ElementRef, error) {
	batch := &accessibility.Batch{}
	focused := batch.Focused(app)
	if err := s.client.Run(ctx, batch); err != nil {
		return nil, err
	}
	if focused.Code != 0 {
		return nil, nil
	}
	ref := focused.Value.Ref
	return &ref, nil
}

func (s *axSession) checkText(ctx context.Context, target *PhoneNode, text string) error {
	batch := &accessibility.Batch{}
	attributes := batch.Attributes(target.AX)
	if err := s.client.Run(ctx, batch); err != nil {
		return err
	}
	if err := attributes.Err("read the element"); err != nil {
		return err
	}
	element := attributes.Value
	if err := element.TextErr(); err != nil {
		return err
	}
	value, placeholder, expected := PlainText(element.Value), PlainText(element.Placeholder), PlainText(text)
	switch {
	// UIKit and WebKit answer a secure entry's value as one • per UTF-16 code
	// unit of its text (24B5110a UIKit.axbundle -[UIView
	// _accessibilitySecureTextForString:] 0x18a046274; WebKit f98a24d3,
	// Source/WebCore/accessibility/ios/WebAccessibilityObjectWrapperIOS.mm:1690,
	// Source/WebCore/accessibility/ios/AccessibilityObjectIOS.mm:107).
	case target.AX.Secure():
		units := len(utf16.Encode([]rune(text)))
		if placeholder != "" && value == placeholder {
			if expected == "" {
				return nil
			}
			return E.New(describeElement(target.AX), " shows its placeholder instead of ", units, " UTF-16 code units")
		}
		if masked := len(utf16.Encode([]rune(value))); masked != units {
			return E.New(describeElement(target.AX), " holds ", masked, " UTF-16 code units after setting ", units)
		}
		return nil
	case placeholder == "" || value != placeholder:
		if value == expected {
			return nil
		}
		return E.New(describeElement(target.AX), " holds ", strconv.Quote(value), " instead of ", strconv.Quote(text))
	case expected != "" && expected != placeholder:
		return E.New(describeElement(target.AX), " shows its placeholder instead of ", strconv.Quote(text))
	}
	empty, err := s.empty(ctx, target)
	if err != nil {
		return err
	}
	if empty != (expected == "") {
		return E.New(describeElement(target.AX), " holds ", strconv.Quote(value), " instead of ", strconv.Quote(text))
	}
	return nil
}

const nativeHandwriting = 2601

// UIKit answers native attribute 2601 with handwriting attributes only for an
// element _accessibilitySupportsHandwriting accepts, and their
// AXVoiceOverHandwritingAttributeCanDeleteCharacter is hasText for a
// UIKeyInput and YES for anything else (24B5110a UIAccessibility 0x1bbde7d10,
// 0x1bbdf8e08, 0x1bbdf8e90, 0x1bbdf9248); WebCore reports its placeholder as
// the value of an empty input (24A446 WebCore.axbundle 0x242ab8a54).
func (s *axSession) empty(ctx context.Context, target *PhoneNode) (bool, error) {
	if target.Web {
		return false, E.New(describeElement(target.AX), " shows its placeholder, and there is no way to tell an empty web input from one holding that text")
	}
	batch := &accessibility.Batch{}
	native := batch.Native(target.AX, nativeHandwriting)
	if err := s.client.Run(ctx, batch); err != nil {
		return false, err
	}
	if err := native.Err("read the handwriting attributes"); err != nil {
		return false, err
	}
	fields, _ := native.Value.(map[string]any)
	deletable, known := fields["AXVoiceOverHandwritingAttributeCanDeleteCharacter"].(bool)
	if !known {
		return false, E.New(describeElement(target.AX), " shows its placeholder, and answers no handwriting attributes that would tell whether it is empty or holds that text")
	}
	return !deletable, nil
}

type action struct {
	unlocked bool
	input    func(ctx context.Context, c *conn, geometry phoneGeometry) error
	check    func(ctx context.Context, c *conn) error
}

func (p *Phone) act(ctx context.Context, do action) error {
	c, ctx, done, err := p.begin(ctx)
	if err != nil {
		return err
	}
	defer done()
	if do.unlocked {
		if err = p.requireScreen(ctx, c); err != nil {
			return err
		}
	}
	geometry, err := c.readGeometry(ctx)
	if err != nil {
		return err
	}
	err = do.input(ctx, c, geometry)
	c.events.publish(Event{Kind: EventInput})
	c.front.acted()
	if err != nil {
		return err
	}
	if do.check != nil {
		if err = do.check(ctx, c); err != nil {
			return E.Cause(err, "check the result")
		}
	}
	return nil
}

func (p *Phone) gesture(ctx context.Context, c *conn, send func(input *hid.Client) error) error {
	grant, err := p.connection.input.acquire(ctx, c)
	if err != nil {
		return err
	}
	defer grant.release()
	return grant.send(send)
}

func (p *Phone) requireScreen(ctx context.Context, c *conn) error {
	locked, err := c.lockState.locked(ctx, c.device)
	if err != nil {
		return E.Cause(err, "read the lock state")
	}
	if locked {
		return E.Extend(ErrLocked, "unlock it first")
	}
	display, err := p.backlight(ctx, c)
	if err != nil {
		return err
	}
	if display == "off" {
		return E.Extend(ErrLocked, "the screen is off; press Home to wake it first")
	}
	return nil
}

func (p *Phone) TapPoint(ctx context.Context, at Point, count int, hold time.Duration) error {
	return p.act(ctx, action{unlocked: true, input: func(ctx context.Context, c *conn, geometry phoneGeometry) error {
		if err := geometry.check(at); err != nil {
			return err
		}
		return p.gesture(ctx, c, func(input *hid.Client) error {
			return tap(ctx, geometry, input, at, count, hold)
		})
	}})
}

func (p *Phone) Touch(ctx context.Context, fingers [][]TouchSample) error {
	return p.act(ctx, action{unlocked: true, input: func(ctx context.Context, c *conn, geometry phoneGeometry) error {
		if err := checkFingers(geometry, fingers); err != nil {
			return err
		}
		return p.gesture(ctx, c, func(input *hid.Client) error {
			return play(ctx, geometry, input, fingers)
		})
	}})
}

func (p *Phone) Pinch(ctx context.Context, center Point, scale float64, duration time.Duration) error {
	return p.act(ctx, action{unlocked: true, input: func(ctx context.Context, c *conn, geometry phoneGeometry) error {
		fingers, err := pinchPath(geometry, center, scale, duration)
		if err != nil {
			return err
		}
		return p.gesture(ctx, c, func(input *hid.Client) error {
			return play(ctx, geometry, input, fingers)
		})
	}})
}

func (p *Phone) Key(ctx context.Context, combo string) error {
	usages, err := parseKeyCombo(combo)
	if err != nil {
		return E.Cause1(ErrInvalid, err)
	}
	return p.act(ctx, action{unlocked: true, input: func(ctx context.Context, c *conn, _ phoneGeometry) error {
		return p.gesture(ctx, c, func(input *hid.Client) error {
			return pressKeys(ctx, input, usages)
		})
	}})
}

var phoneButtons = map[string][]hid.Button{
	"home": {hid.ButtonHome}, "appSwitcher": {hid.ButtonHome, hid.ButtonHome},
	"power": {{UsagePage: hid.ButtonLock.UsagePage, Usage: hid.ButtonLock.Usage}}, "volumeUp": {hid.ButtonVolumeUp}, "volumeDown": {hid.ButtonVolumeDown},
}

const springboardBundleID = "com.apple.springboard"

func (p *Phone) Button(ctx context.Context, name string) error {
	buttons, known := phoneButtons[name]
	if !known {
		return E.Extend(ErrInvalid, "unknown button ", strconv.Quote(name))
	}
	var check func(ctx context.Context, c *conn) error
	if name == "home" {
		check = func(ctx context.Context, c *conn) error {
			_, err := c.front.waitFor(ctx, springboardBundleID, time.Now().Add(launchLimit))
			return err
		}
	}
	return p.act(ctx, action{
		input: func(ctx context.Context, c *conn, _ phoneGeometry) error {
			return p.gesture(ctx, c, func(input *hid.Client) error {
				for index, button := range buttons {
					if index > 0 {
						if err := sleep(ctx, homeGap); err != nil {
							return err
						}
					}
					if err := input.PressButton(ctx, button); err != nil {
						return err
					}
				}
				return nil
			})
		},
		check: check,
	})
}

func (p *Phone) Launch(ctx context.Context, bundleID, url string, restart, animated bool) error {
	var started time.Time
	return p.act(ctx, action{
		unlocked: true,
		input: func(ctx context.Context, c *conn, _ phoneGeometry) error {
			started = time.Now()
			launchContext, cancel := context.WithDeadline(ctx, started.Add(launchLimit))
			defer cancel()
			err := apps.Launch(launchContext, c.device, bundleID, url, restart, animated)
			if err == nil {
				return nil
			}
			list, listErr := apps.List(ctx, c.device)
			if listErr == nil && !slices.ContainsFunc(list, func(app apps.App) bool { return app.BundleID == bundleID }) {
				return E.Cause1(ErrNotFound, E.Cause(err, "no app with the bundle ID ", strconv.Quote(bundleID), " is listed"))
			}
			return E.Append(err, listErr, func(err error) error { return E.Cause(err, "list the apps") })
		},
		check: func(ctx context.Context, c *conn) error {
			front, err := c.front.waitFor(ctx, bundleID, started.Add(launchLimit))
			if err != nil {
				return err
			}
			if front != bundleID {
				return E.New(bundleID, " launched, but ", front, " is still in front after ", launchLimit)
			}
			return nil
		},
	})
}

func (p *Phone) Unlock(ctx context.Context) error {
	settings := p.connection.settings.Load()
	if settings.AutoUnlockPasscode == "" {
		return E.New("no unlock passcode is configured")
	}
	return p.act(ctx, action{input: func(ctx context.Context, c *conn, _ phoneGeometry) error {
		grant, err := p.connection.input.acquire(ctx, c)
		if err != nil {
			return err
		}
		defer grant.release()
		if err = grant.closeSoftware(); err != nil {
			return err
		}
		target := &deviceUnlockTarget{connection: p.connection, settings: settings, conn: c, input: grant.hardware(), keys: newKeyboard(), logger: p.logger}
		_, err = target.unlock(ctx)
		grant.settleHardware(err)
		if err != nil {
			return E.Cause(err, "unlock")
		}
		return nil
	}})
}
