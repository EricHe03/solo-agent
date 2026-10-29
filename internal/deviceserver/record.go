package deviceserver

import (
	"context"
	"time"

	"github.com/swipt-automation/swipt/internal/coredevice/accessibility"
	"github.com/swipt-automation/swipt/internal/coredevice/apps"
	"github.com/swipt-automation/swipt/internal/coredevice/instruments"
)

type Recorded struct {
	Time time.Time
	App  *RecordedApp
	AX   *accessibility.Push
}

type RecordedApp struct {
	BundleID string
	PID      uint64
	State    string
}

type Recording struct {
	phone   *Phone
	states  *instruments.AppStates
	bundles map[string]string
	done    chan struct{}
	pushes  []Recorded
}

func (p *Phone) Record(ctx context.Context) (*Recording, error) {
	a, ctx, cancel, err := p.begin(ctx)
	if err != nil {
		return nil, err
	}
	defer cancel()
	installed, err := apps.List(ctx, a.device)
	if err != nil {
		return nil, err
	}
	states, err := instruments.DialAppStates(ctx, a.ctx, a.device)
	if err != nil {
		return nil, err
	}
	r := &Recording{phone: p, states: states, bundles: make(map[string]string), done: make(chan struct{})}
	for _, app := range installed {
		r.bundles[app.Path] = app.BundleID
	}
	p.recordAccess.Lock()
	p.recordings[r] = struct{}{}
	p.recordAccess.Unlock()
	go r.watch(time.Now().Add(appStatesBacklog))
	err = p.withAccessibility(ctx, a, true, func(*accessibility.RemoteClient) error { return nil })
	if err != nil {
		r.Stop()
		return nil, err
	}
	return r, nil
}

func (r *Recording) watch(backlog time.Time) {
	defer close(r.done)
	for {
		select {
		case state := <-r.states.States():
			if time.Now().Before(backlog) {
				continue
			}
			app := &RecordedApp{BundleID: r.bundles[state.Path], PID: state.PID, State: state.State}
			if app.BundleID == "" {
				app.BundleID = state.Name
			}
			r.phone.recordAccess.Lock()
			r.pushes = append(r.pushes, Recorded{Time: time.Now(), App: app})
			r.phone.recordAccess.Unlock()
		case <-r.states.Done():
			return
		}
	}
}

func (r *Recording) Stop() []Recorded {
	p := r.phone
	p.recordAccess.Lock()
	delete(p.recordings, r)
	p.recordAccess.Unlock()
	if err := r.states.Close(); err != nil {
		p.logger.Debug("stop recording app states", "error", err)
	}
	<-r.done
	p.recordAccess.Lock()
	defer p.recordAccess.Unlock()
	return r.pushes
}

func (p *Phone) recordPush(push accessibility.Push) {
	now := time.Now()
	p.recordAccess.Lock()
	defer p.recordAccess.Unlock()
	for r := range p.recordings {
		r.pushes = append(r.pushes, Recorded{Time: now, AX: &push})
	}
}
