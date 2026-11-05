package device

import (
	"context"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice/accessibility"
)

func (p *Phone) Find(ctx context.Context, selectors []*Selector) (*View, uint64, error) {
	if len(selectors) == 0 {
		return nil, 0, E.Extend(ErrInvalid, "find needs a selector")
	}
	var fields, named []string
	scripted, unnamed := false, false
	for _, selector := range selectors {
		scripted = scripted || selector.Scripted()
		fields = append(fields, selector.Fields()...)
		switch app := selector.App(); {
		case app == "":
			unnamed = true
		case !slices.Contains(named, app):
			named = append(named, app)
		}
	}
	options := accessibility.ApplicationOptions{Modal: slices.Contains(fields, "inert"), Focused: slices.Contains(fields, "focused")}
	if !scripted {
		options.Attributes = accessibility.SnapshotAttributes(fields)
	}
	c, ctx, done, err := p.begin(ctx)
	if err != nil {
		return nil, 0, err
	}
	defer done()
	began := time.Now()
	geometry, err := c.readGeometry(ctx)
	if err != nil {
		return nil, 0, err
	}
	geometryTook := time.Since(began)
	seen := c.events.screen.Load()
	key := "find:" + strings.Join(named, ",")
	switch {
	case !unnamed && len(named) == 1 && named[0] == springboardBundleID:
		if options.PID, err = c.springboardPID(ctx); err != nil {
			return nil, 0, err
		}
	case !unnamed:
		options.Wanted = func(bundleID string) bool { return slices.Contains(named, bundleID) }
	default:
		key = "find"
	}
	key += ":" + strconv.FormatUint(options.PID, 10) + ":" + strconv.FormatBool(options.Modal) + ":" + strconv.FormatBool(options.Focused) + ":" + fmt.Sprint(options.Attributes)
	queued := time.Now()
	value, err := c.ax.read(ctx, key, func(ctx context.Context, client *accessibility.RemoteClient) (any, error) {
		started := time.Now()
		screen, err := client.ReadApplication(ctx, options)
		waits := "geometry " + geometryTook.String() + ", queued " + started.Sub(queued).String()
		if err != nil {
			p.connection.trace(started, "find.failed", waits+", "+err.Error(), time.Since(started))
			if options.PID != 0 && E.IsMulti(err, accessibility.ErrNoAnswer, accessibility.ErrNoApplication) {
				c.springboard.CompareAndSwap(options.PID, 0)
			}
			return nil, err
		}
		if screen.Root == nil {
			p.connection.trace(started, "find.skipped", waits+", "+screen.BundleID+" pid "+strconv.FormatUint(screen.App.Ref.PID, 10)+" is in front", time.Since(started))
			c.front.observed(frontApplication{pid: screen.App.Ref.PID, bundleID: screen.BundleID, at: started, via: "find"})
			return (*PhoneModel)(nil), nil
		}
		model := p.model(c, geometry, screen, started, options.PID == 0)
		p.connection.trace(started, "find.read", waits+", "+strconv.Itoa(len(model.nodes))+" nodes of "+screen.BundleID+", "+strconv.FormatUint(c.events.screen.Load()-seen, 10)+" screen changes since", time.Since(started))
		return model, nil
	})
	if err != nil {
		return nil, 0, err
	}
	model := value.(*PhoneModel)
	if model == nil {
		return nil, seen, nil
	}
	c.nodes.add(model)
	return NewView(model, true), seen, nil
}

func (p *Phone) Changed(ctx context.Context, seen uint64, timeout time.Duration) error {
	c, ctx, done, err := p.begin(ctx)
	if err != nil {
		return err
	}
	defer done()
	changed, stop := c.events.watch(true)
	defer stop()
	if c.events.screen.Load() != seen {
		p.connection.trace(time.Now(), "changed", "already "+strconv.FormatUint(c.events.screen.Load()-seen, 10)+" screen changes", 0)
		return nil
	}
	var expire <-chan time.Time
	if timeout >= 0 {
		timer := time.NewTimer(timeout)
		defer timer.Stop()
		expire = timer.C
	}
	started := time.Now()
	select {
	case <-changed:
		p.connection.trace(started, "changed", "woken by a push", time.Since(started))
	case <-expire:
		p.connection.trace(started, "changed", "timed out", time.Since(started))
	case <-ctx.Done():
		return ctx.Err()
	}
	return nil
}

func (p *Phone) element(c *conn, ref string) (*PhoneNode, error) {
	parsed, err := parseRef(ref)
	if err != nil {
		return nil, err
	}
	node := c.nodes.find(parsed, c.ax.current())
	if node == nil {
		return nil, E.Extend(ErrNotFound, "the element is not from a current read of the screen; read the screen again")
	}
	return node, nil
}

func (p *Phone) Perform(ctx context.Context, ref, name string) (Aim, error) {
	c, ctx, done, err := p.begin(ctx)
	if err != nil {
		return Aim{}, err
	}
	defer done()
	geometry, err := c.readGeometry(ctx)
	if err != nil {
		return Aim{}, err
	}
	started := time.Now()
	s := &axSession{phone: p, conn: c, geometry: geometry}
	err = c.ax.do(ctx, true, 0, func(ctx context.Context, client *accessibility.RemoteClient) error {
		s.client = client
		node, err := p.element(c, ref)
		if err != nil {
			return err
		}
		s.target = Aim{Element: describeElement(node.AX)}
		return s.perform(ctx, node, name)
	})
	p.connection.trace(started, "perform.element", s.target.String()+", "+name, time.Since(started))
	if s.acted {
		c.events.publish(Event{Kind: EventInput})
		c.front.acted()
	}
	return s.target, err
}
