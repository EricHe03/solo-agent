package device

import (
	"context"
	"math"
	"strconv"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice/accessibility"
)

func (p *Phone) Tap(ctx context.Context, ref string, timeout time.Duration) error {
	return p.aimed(ctx, ref, timeout, "tap", func(ctx context.Context, s *axSession, _ *PhoneNode, at Point) error {
		return s.tap(ctx, at, 1, 0)
	})
}

func (p *Phone) SetText(ctx context.Context, ref, text string, timeout time.Duration) error {
	return p.aimed(ctx, ref, timeout, "setText", func(ctx context.Context, s *axSession, node *PhoneNode, at Point) error {
		return s.setText(ctx, node, at, text)
	})
}

// aimed runs act on the element once a tap at the point it answers would reach
// it, checking again while the element is moving, disabled or behind another
// one, until the timeout; a negative timeout waits forever and zero checks once.
func (p *Phone) aimed(ctx context.Context, ref string, timeout time.Duration, name string, act func(ctx context.Context, s *axSession, node *PhoneNode, at Point) error) error {
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
	grant, err := p.connection.input.acquire(ctx, c)
	if err != nil {
		return err
	}
	defer grant.release()
	s := &axSession{phone: p, conn: c, geometry: geometry, grant: grant}
	var deadline time.Time
	if timeout >= 0 {
		deadline = time.Now().Add(timeout)
	}
	started := time.Now()
	var delay time.Duration
	for attempt := 1; ; attempt++ {
		var pending string
		err = c.ax.do(ctx, true, 0, func(ctx context.Context, client *accessibility.RemoteClient) error {
			s.client = client
			node, err := p.element(c, ref)
			if err != nil {
				return err
			}
			at, reason, err := s.aim(ctx, node)
			if err != nil || reason != "" {
				pending = reason
				return err
			}
			return act(ctx, s, node, at)
		})
		if err != nil || pending == "" {
			p.connection.trace(started, name+".element", "attempt "+strconv.Itoa(attempt), time.Since(started))
			break
		}
		delay = min(max(delay*2, pollFirst), pollLongest)
		if !deadline.IsZero() && time.Now().Add(delay).After(deadline) {
			p.connection.trace(started, name+".refused", pending, time.Since(started))
			if timeout == 0 {
				return E.Extend(ErrTimeout, pending)
			}
			return E.Extend(ErrTimeout, pending, "; gave up after ", timeout)
		}
		if err = sleep(ctx, delay); err != nil {
			return err
		}
	}
	if s.acted {
		c.events.publish(Event{Kind: EventInput})
		c.front.acted()
	}
	return err
}

func (s *axSession) aim(ctx context.Context, target *PhoneNode) (Point, string, error) {
	name := describeElement(target.AX)
	switch {
	case !target.HasFrame():
		return Point{}, "", E.New(name, " has no position on the screen; perform one of its actions instead")
	case !target.AX.Enabled:
		return Point{}, name + " is disabled", nil
	case !target.Shown():
		return Point{}, name + " is off the screen", nil
	case target.Covered:
		return Point{}, name + " is covered", nil
	}
	at := target.Point
	batch := &accessibility.Batch{}
	mapped := batch.Mapped(target.AX)
	attributes := batch.Attributes(target.AX)
	hit := batch.HitTest(s.geometry.digitizer(at))
	if err := s.client.Run(ctx, batch); err != nil {
		return Point{}, "", err
	}
	previous := s.previous
	s.previous = attributes.Value.Frame
	switch {
	case mapped.Code == 0 && !mapped.Value:
		return Point{}, name + " is gone", nil
	case mapped.Code != 0 || attributes.Code != 0:
		return Point{}, name + " did not answer", nil
	case !attributes.Value.Enabled:
		return Point{}, name + " is disabled", nil
	case previous != nil && !nearFrame(attributes.Value.Frame, previous):
		return Point{}, name + " is moving", nil
	}
	if fresh := attributes.Value.Frame; fresh != nil {
		if rect := target.space.rect(*fresh); !rect.Empty() && !rect.Contains(at) {
			at = rect.Center()
			again := &accessibility.Batch{}
			hit = again.HitTest(s.geometry.digitizer(at))
			if err := s.client.Run(ctx, again); err != nil {
				return Point{}, "", err
			}
		}
	}
	if hit.Code != 0 {
		return Point{}, "the device does not tell which element is at " + pointText(at), nil
	}
	node := target.model.Node(hit.Value.Ref)
	switch {
	case hit.Value.Ref == target.AX.Ref, node != nil && (target.Contains(node) || hit.Value.AccessibilityElement && node.Contains(target)):
		return at, "", nil
	case node == nil:
		read := &accessibility.Batch{}
		element := read.Attributes(hit.Value)
		if err := s.client.Run(ctx, read); err != nil {
			return Point{}, "", err
		}
		if element.Code == 0 && sameWindow(target, element.Value) {
			return at, "", nil
		}
		hit.Value = element.Value
	}
	if target.Inert {
		return Point{}, name + " is behind a modal view, as a sheet or an alert", nil
	}
	return Point{}, "a tap at " + pointText(at) + " would reach " + describeElement(hit.Value) + ", not " + name, nil
}

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

func nearFrame(first, second *accessibility.LayoutFrame) bool {
	if first == nil || second == nil {
		return first == second
	}
	return math.Abs(first.X-second.X) < 1 && math.Abs(first.Y-second.Y) < 1 && math.Abs(first.Width-second.Width) < 1 && math.Abs(first.Height-second.Height) < 1
}
