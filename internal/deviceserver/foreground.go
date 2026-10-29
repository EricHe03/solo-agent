package deviceserver

import (
	"context"
	"errors"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice/accessibility"
	"github.com/swipt-automation/swipt/internal/coredevice/apps"
	"github.com/swipt-automation/swipt/internal/coredevice/instruments"
)

// Enabling the notifications sent the state of every app within 40 ms. They
// report a process as Running when it starts or resumes and again when it is
// suspended, and the frontmost application turned to a cold-launched app 70 to
// 550 ms after its process was reported (iPhone18,2, iOS 27.2 24B115).
const (
	appStatesBacklog    = 250 * time.Millisecond
	foregroundPoll      = 250 * time.Millisecond
	foregroundBurst     = time.Second
	foregroundBurstPoll = 50 * time.Millisecond
)

type ForegroundApp struct {
	BundleID string
	PID      uint64
}

type frontApplication struct {
	app      accessibility.Element
	bundleID string
	at       time.Time
}

func (p *Phone) recentFront() (frontApplication, bool) {
	p.frontAccess.Lock()
	defer p.frontAccess.Unlock()
	return p.front, time.Since(p.front.at) < foregroundPoll
}

func (p *Phone) sawFront(generation uint64, seen time.Time, app accessibility.Element, bundleID string) {
	p.frontAccess.Lock()
	defer p.frontAccess.Unlock()
	if generation == p.frontGeneration.Load() && seen.After(p.front.at) {
		p.front = frontApplication{app: app, bundleID: bundleID, at: seen}
	}
}

func (p *Phone) forgetFront() {
	p.frontAccess.Lock()
	defer p.frontAccess.Unlock()
	p.front = frontApplication{}
	p.frontGeneration.Add(1)
}

func (p *Phone) WatchForeground(ctx context.Context, emit func(ForegroundApp)) {
	var front ForegroundApp
	for {
		err := p.watchForeground(ctx, &front, emit)
		if ctx.Err() != nil {
			return
		}
		p.logger.Warn("watch the foreground app", "error", err)
		if sleep(ctx, time.Second) != nil {
			return
		}
	}
}

func (p *Phone) watchForeground(ctx context.Context, front *ForegroundApp, emit func(ForegroundApp)) error {
	a, err := p.server.waitDevice(ctx)
	if err != nil {
		return err
	}
	ctx, cancel := inputContext(a, ctx)
	defer cancel()
	bundles := make(map[string]string)
	installed, err := apps.List(ctx, a.device)
	if err != nil {
		p.logger.Debug("list apps", "error", err)
	}
	for _, app := range installed {
		if app.Path != "" {
			bundles[app.Path] = app.BundleID
		}
	}
	paths := make(map[uint64]string)
	record := func(state instruments.AppState) {
		switch {
		case state.State == "Terminated":
			delete(paths, state.PID)
		case state.Path != "":
			paths[state.PID] = state.Path
		}
	}
	var pushes <-chan instruments.AppState
	bundleOf := func(pid uint64) string {
		for bundles[paths[pid]] == "" {
			select {
			case state := <-pushes:
				record(state)
			default:
				return ""
			}
		}
		return bundles[paths[pid]]
	}
	var pushesDone <-chan struct{}
	states, err := instruments.DialAppStates(ctx, ctx, a.device)
	if err != nil {
		p.logger.Debug("watch app states", "error", err)
	} else {
		defer states.Close()
		pushes, pushesDone = states.States(), states.Done()
	}
	backlog := time.Now().Add(appStatesBacklog)
	report := func(app ForegroundApp) {
		*front = app
		if path := paths[app.PID]; path != "" {
			bundles[path] = app.BundleID
		}
		emit(app)
	}
	app, err := p.frontApp(ctx, a, *front, bundleOf)
	if err != nil {
		return err
	}
	if front.PID == 0 {
		*front = app
	} else if app.PID != front.PID {
		report(app)
	}
	poll := time.NewTimer(foregroundPoll)
	defer poll.Stop()
	var burst time.Time
	for {
		select {
		case <-poll.C:
		case state := <-pushes:
			record(state)
			if time.Now().Before(backlog) {
				continue
			}
			if state.PID == front.PID && state.State != "Running" || state.PID != front.PID && state.State == "Running" && bundles[state.Path] != "" {
				p.forgetFront()
			}
			if state.State != "Running" {
				continue
			}
			burst = time.Now().Add(foregroundBurst)
		case <-pushesDone:
			p.logger.Debug("watch app states", "error", states.Err())
			pushes, pushesDone = nil, nil
			continue
		case <-ctx.Done():
			return ctx.Err()
		}
		if seen, recent := p.recentFront(); recent && !time.Now().Before(burst) {
			app = ForegroundApp{BundleID: seen.bundleID, PID: seen.app.Ref.PID}
		} else if app, err = p.frontApp(ctx, a, *front, bundleOf); err != nil {
			return err
		}
		if app.PID != front.PID {
			burst = time.Time{}
			report(app)
		}
		if time.Now().Before(burst) {
			poll.Reset(foregroundBurstPoll)
		} else {
			poll.Reset(foregroundPoll)
		}
	}
}

func (p *Phone) frontApp(ctx context.Context, a *attachment, known ForegroundApp, bundleOf func(uint64) string) (front ForegroundApp, err error) {
	generation := p.frontGeneration.Load()
	seen := time.Now()
	err = p.withAccessibility(ctx, a, true, func(client *accessibility.RemoteClient) error {
		batch := &accessibility.Batch{}
		app := batch.Frontmost()
		if err := client.Run(ctx, batch); err != nil {
			return err
		}
		if err := app.Err("read the frontmost application"); err != nil {
			return err
		}
		front.PID = app.Value.Ref.PID
		if front.PID == known.PID {
			front.BundleID = known.BundleID
		} else {
			front.BundleID = bundleOf(front.PID)
		}
		if front.BundleID == "" {
			read := &accessibility.Batch{}
			bundle := read.BundleID(app.Value)
			if err := client.Run(ctx, read); err != nil {
				return err
			}
			if err := bundle.Err("read the frontmost application's bundle ID"); err != nil {
				return err
			}
			front.BundleID = bundle.Value
		}
		p.sawFront(generation, seen, app.Value, front.BundleID)
		return nil
	})
	return
}

func (p *Phone) ReadFront(ctx context.Context, attributes []int64) (*PhoneModel, error) {
	a, ctx, cancel, err := p.begin(ctx)
	if err != nil {
		return nil, err
	}
	defer cancel()
	var geometry phoneGeometry
	var geometryErr error
	geometryRead := make(chan struct{})
	go func() {
		geometry, geometryErr = p.readGeometry(ctx, a)
		close(geometryRead)
	}()
	var screen *accessibility.Screen
	err = p.withAccessibility(ctx, a, true, func(client *accessibility.RemoteClient) (err error) {
		if front, recent := p.recentFront(); recent {
			screen, err = client.ReadApplication(ctx, front.app, attributes)
			if errors.Is(err, accessibility.ErrStalled) || err == nil && screen.BundleID == front.bundleID {
				return
			}
		}
		generation := p.frontGeneration.Load()
		seen := time.Now()
		screen, err = client.ReadFront(ctx, attributes)
		if err == nil {
			p.sawFront(generation, seen, screen.App, screen.BundleID)
		}
		return
	})
	<-geometryRead
	if err = E.Errors(err, geometryErr); err != nil {
		return nil, err
	}
	return modelOf(geometry, screen), nil
}

func (p *Phone) HitTest(ctx context.Context, at Point) (accessibility.Element, error) {
	a, ctx, cancel, err := p.begin(ctx)
	if err != nil {
		return accessibility.Element{}, err
	}
	defer cancel()
	geometry, err := p.readGeometry(ctx, a)
	if err != nil {
		return accessibility.Element{}, err
	}
	if err = geometry.check(at); err != nil {
		return accessibility.Element{}, err
	}
	return p.hitTest(ctx, a, geometry, at)
}
