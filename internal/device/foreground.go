package device

import (
	"context"
	"sync"
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
	appStatesBacklog = 250 * time.Millisecond
	recentFront      = 250 * time.Millisecond
	frontBurst       = 1200 * time.Millisecond
	trackingLinger   = 10 * time.Second
)

// AXP notification 3, which the translator forwards at once for a change of
// first responder or native focus (24B5110a AccessibilityPlatformTranslation
// __axEventHandler 0x253fd8ba0, -[AXPRemoteCacheManager
// handleNotification:data:associatedObject:] 0x253fe623c); launching or
// switching to an app sometimes sent it (iPhone18,2, iOS 27.2 24B115).
const notificationFocusChanged = 3

type ForegroundApp struct {
	BundleID string
	PID      uint64
	Launched bool
	At       time.Time
}

type frontApplication struct {
	pid      uint64
	bundleID string
	at       time.Time
}

func (a frontApplication) app() bool {
	return a.pid != 0 && a.bundleID != springboardBundleID
}

type foreground struct {
	conn *conn

	access    sync.Mutex
	current   frontApplication
	frontmost uint64
	tracked   bool
	listeners map[int]func(ForegroundApp)
	next      int
	stop      context.CancelFunc
	stopped   chan struct{}
	linger    *time.Timer
	until     time.Time
	pending   uint64
	kick      chan struct{}
	bundles   map[string]string
	paths     map[uint64]string
	existing  map[uint64]bool
	fronted   map[uint64]bool
	probes    map[uint64]time.Time
}

func newForeground(c *conn) *foreground {
	return &foreground{
		conn: c, listeners: make(map[int]func(ForegroundApp)), kick: make(chan struct{}, 1), paths: make(map[uint64]string),
		fronted: make(map[uint64]bool), probes: make(map[uint64]time.Time),
	}
}

func (f *foreground) get(ctx context.Context) (frontApplication, error) {
	f.access.Lock()
	current, tracked := f.current, f.tracked
	f.access.Unlock()
	if tracked && current.bundleID != "" || time.Since(current.at) < recentFront {
		return current, nil
	}
	return f.read(ctx)
}

func (f *foreground) read(ctx context.Context) (frontApplication, error) {
	value, err := f.conn.ax.read(ctx, "frontmost", func(ctx context.Context, client *accessibility.RemoteClient) (any, error) {
		seen := time.Now()
		batch := &accessibility.Batch{}
		front := batch.Frontmost()
		if err := client.Run(ctx, batch); err != nil {
			return nil, err
		}
		if err := front.Err("read the frontmost application"); err != nil {
			return nil, err
		}
		bundleID := f.bundleOf(front.Value.Ref.PID)
		if bundleID == "" {
			read := &accessibility.Batch{}
			bundle := read.BundleID(front.Value)
			if err := client.Run(ctx, read); err != nil {
				return nil, err
			}
			if err := bundle.Err("read the frontmost application's bundle ID"); err != nil {
				return nil, err
			}
			bundleID = bundle.Value
		}
		return frontApplication{pid: front.Value.Ref.PID, bundleID: bundleID, at: seen}, nil
	})
	if err != nil {
		return frontApplication{}, err
	}
	front := value.(frontApplication)
	f.access.Lock()
	f.frontmost = front.pid
	f.access.Unlock()
	if front.bundleID == springboardBundleID {
		front = f.beneath(ctx, front)
	}
	return f.saw(front), nil
}

// The frontmost application is SpringBoard on the home screen and also while
// one of its alerts, such as the paste prompt, covers an application
// (iPhone18,2, iOS 27.2 24B115).
func (f *foreground) beneath(ctx context.Context, springboard frontApplication) frontApplication {
	f.access.Lock()
	current := f.current
	var pids []uint64
	if current.app() {
		pids = append(pids, current.pid)
	}
	for pid, until := range f.probes {
		switch {
		case until.Before(springboard.at):
			delete(f.probes, pid)
		case pid != current.pid && pid != springboard.pid:
			pids = append(pids, pid)
		}
	}
	f.access.Unlock()
	if len(pids) == 0 {
		return springboard
	}
	shown, err := instruments.ForegroundProcesses(ctx, f.conn.device, pids)
	if err != nil {
		if ctx.Err() == nil {
			f.conn.logger.Debug(E.Cause(err, "read the foreground state of processes"))
		}
		return springboard
	}
	switch {
	case len(shown) == 0:
		return springboard
	case shown[0] == current.pid:
		return frontApplication{pid: current.pid, bundleID: current.bundleID, at: springboard.at}
	}
	if bundleID := f.bundleOf(shown[0]); bundleID != "" {
		return frontApplication{pid: shown[0], bundleID: bundleID, at: springboard.at}
	}
	return springboard
}

func (f *foreground) observed(front frontApplication) {
	f.access.Lock()
	moved := front.pid != f.frontmost
	f.frontmost = front.pid
	held := front.bundleID == springboardBundleID && f.current.app()
	f.access.Unlock()
	switch {
	case !held:
		f.saw(front)
	case moved:
		f.trigger(0)
	}
}

func (f *foreground) bundleOf(pid uint64) string {
	f.access.Lock()
	defer f.access.Unlock()
	if f.bundles == nil {
		return ""
	}
	return f.bundles[f.paths[pid]]
}

func (f *foreground) knownBundle(pid uint64) string {
	if bundleID := f.bundleOf(pid); bundleID != "" {
		return bundleID
	}
	f.access.Lock()
	defer f.access.Unlock()
	if f.current.pid == pid {
		return f.current.bundleID
	}
	return ""
}

func (f *foreground) saw(front frontApplication) frontApplication {
	f.access.Lock()
	defer f.access.Unlock()
	if !front.at.After(f.current.at) {
		return f.current
	}
	pid := front.pid
	changed := pid != f.current.pid || front.bundleID != f.current.bundleID
	launched := changed && f.existing != nil && !f.existing[pid] && !f.fronted[pid]
	f.current = front
	f.fronted[pid] = true
	if path := f.paths[pid]; path != "" && f.bundles != nil {
		f.bundles[path] = front.bundleID
	}
	if !changed {
		return front
	}
	app := ForegroundApp{BundleID: front.bundleID, PID: pid, Launched: launched, At: front.at}
	f.conn.events.publish(Event{Kind: EventForeground, PID: app.PID, BundleID: app.BundleID})
	for _, listener := range f.listeners {
		listener(app)
	}
	return front
}

func (f *foreground) watch(listener func(ForegroundApp)) (cancel func()) {
	f.access.Lock()
	f.next++
	id := f.next
	f.listeners[id] = listener
	if f.linger != nil {
		f.linger.Stop()
		f.linger = nil
	}
	if f.stop == nil {
		ctx, stop := context.WithCancel(f.conn.ctx)
		f.stop, f.stopped = stop, make(chan struct{})
		go f.track(ctx, f.stopped)
	}
	f.access.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			f.access.Lock()
			defer f.access.Unlock()
			delete(f.listeners, id)
			if len(f.listeners) > 0 || f.stop == nil {
				return
			}
			var linger *time.Timer
			linger = time.AfterFunc(trackingLinger, func() {
				f.access.Lock()
				defer f.access.Unlock()
				if f.linger == linger && len(f.listeners) == 0 && f.stop != nil {
					f.stop()
					f.stop, f.tracked, f.linger = nil, false, nil
				}
			})
			f.linger = linger
		})
	}
}

func (f *foreground) trigger(window time.Duration) {
	f.access.Lock()
	if until := time.Now().Add(window); until.After(f.until) {
		f.until = until
	}
	f.access.Unlock()
	select {
	case f.kick <- struct{}{}:
	default:
	}
}

func (f *foreground) acted() {
	f.access.Lock()
	if !f.tracked {
		f.current.at = time.Time{}
	}
	f.access.Unlock()
	f.trigger(frontBurst)
}

func (f *foreground) pushed(push accessibility.Push) {
	switch {
	case push.Frontmost != nil:
		pid := push.Frontmost.Ref.PID
		f.access.Lock()
		changed := f.stop != nil && pid != f.current.pid && pid != f.frontmost
		f.frontmost = pid
		if changed {
			f.pending = pid
		}
		f.access.Unlock()
		if changed {
			f.trigger(0)
		}
	case push.Notification == notificationFocusChanged:
		f.trigger(frontBurst)
	}
}

func (f *foreground) track(ctx context.Context, stopped chan struct{}) {
	defer close(stopped)
	if err := f.loadBundles(ctx); err != nil && ctx.Err() == nil {
		f.conn.logger.Debug(E.Cause(err, "list apps"))
	}
	if err := f.loadExisting(ctx); err != nil && ctx.Err() == nil {
		f.conn.logger.Debug(E.Cause(err, "list processes"))
	}
	var pushes <-chan instruments.AppState
	var pushesDone <-chan struct{}
	states, err := instruments.DialAppStates(ctx, ctx, f.conn.device)
	if err != nil {
		if ctx.Err() != nil {
			return
		}
		f.conn.logger.Debug(E.Cause(err, "watch app states"))
	} else {
		defer states.Close()
		pushes, pushesDone = states.States(), states.Done()
	}
	backlog := time.Now().Add(appStatesBacklog)
	f.confirm(ctx, 0)
	confirm := time.NewTimer(time.Hour)
	confirm.Stop()
	defer confirm.Stop()
	var delay time.Duration
	for {
		select {
		case state := <-pushes:
			relevant := f.record(state)
			if time.Now().Before(backlog) {
				continue
			}
			f.conn.events.publish(Event{Kind: EventAppState, PID: state.PID, Name: state.State})
			if relevant {
				f.trigger(frontBurst)
			}
			continue
		case <-pushesDone:
			f.conn.logger.Debug("watch app states: ", states.Err())
			pushes, pushesDone = nil, nil
			continue
		case <-f.kick:
			delay = 0
		case <-confirm.C:
		case <-ctx.Done():
			return
		}
		f.access.Lock()
		pending, until := f.pending, f.until
		f.pending = 0
		f.access.Unlock()
		f.confirm(ctx, pending)
		if left := time.Until(until); left > 0 {
			delay = min(max(delay*2, pollFirst), pollLongest)
			confirm.Reset(min(delay, left))
		}
	}
}

func (f *foreground) confirm(ctx context.Context, pushed uint64) {
	if pushed != 0 {
		if bundleID := f.bundleOf(pushed); bundleID != "" && bundleID != springboardBundleID {
			f.saw(frontApplication{pid: pushed, bundleID: bundleID, at: time.Now()})
			f.markTracked()
			return
		}
	}
	if _, err := f.read(ctx); err != nil {
		if ctx.Err() == nil {
			f.conn.logger.Debug(E.Cause(err, "read the frontmost application"))
		}
		return
	}
	f.markTracked()
}

func (f *foreground) markTracked() {
	f.access.Lock()
	f.tracked = f.stop != nil
	f.access.Unlock()
}

func (f *foreground) loadBundles(ctx context.Context) error {
	f.access.Lock()
	loaded := f.bundles != nil
	f.access.Unlock()
	if loaded {
		return nil
	}
	installed, err := apps.List(ctx, f.conn.device)
	if err != nil {
		return err
	}
	bundles := make(map[string]string)
	for _, app := range installed {
		if app.Path != "" {
			bundles[app.Path] = app.BundleID
		}
	}
	f.access.Lock()
	f.bundles = bundles
	f.access.Unlock()
	return nil
}

func (f *foreground) loadExisting(ctx context.Context) error {
	f.access.Lock()
	loaded := f.existing != nil
	f.access.Unlock()
	if loaded {
		return nil
	}
	processes, err := apps.Processes(ctx, f.conn.device)
	if err != nil {
		return err
	}
	existing := make(map[uint64]bool, len(processes))
	for _, process := range processes {
		existing[process.PID] = true
	}
	f.access.Lock()
	f.existing = existing
	f.access.Unlock()
	return nil
}

func (f *foreground) record(state instruments.AppState) (relevant bool) {
	f.access.Lock()
	defer f.access.Unlock()
	switch {
	case state.State == "Terminated":
		delete(f.paths, state.PID)
		delete(f.probes, state.PID)
	case state.Path != "":
		f.paths[state.PID] = state.Path
	}
	if state.PID == f.current.pid {
		return true
	}
	if state.State != "Running" || f.bundles[state.Path] == "" {
		return false
	}
	f.probes[state.PID] = time.Now().Add(frontBurst)
	return true
}

func (f *foreground) waitFor(ctx context.Context, bundleID string, deadline time.Time) (string, error) {
	changed := make(chan struct{}, 1)
	cancel := f.watch(func(ForegroundApp) {
		select {
		case changed <- struct{}{}:
		default:
		}
	})
	defer cancel()
	f.trigger(time.Until(deadline))
	for {
		front, err := f.get(ctx)
		if err != nil || front.bundleID == bundleID {
			return front.bundleID, err
		}
		timer := time.NewTimer(time.Until(deadline))
		select {
		case <-changed:
		case <-timer.C:
			return front.bundleID, nil
		case <-ctx.Done():
			timer.Stop()
			return front.bundleID, ctx.Err()
		}
		timer.Stop()
	}
}

func (f *foreground) close() {
	f.access.Lock()
	stop, stopped := f.stop, f.stopped
	f.stop = nil
	if f.linger != nil {
		f.linger.Stop()
		f.linger = nil
	}
	f.access.Unlock()
	if stop != nil {
		stop()
		<-stopped
	}
}

type AppEvent struct {
	Kind     string
	BundleID string
	PID      uint64
	Time     time.Time
}

func (p *Phone) WatchApps(ctx context.Context, emit func(AppEvent)) error {
	var last ForegroundApp
	for {
		c, operation, done, err := p.begin(ctx)
		if err != nil {
			return err
		}
		var access sync.Mutex
		var queued []ForegroundApp
		changed := make(chan struct{}, 1)
		cancel := c.front.watch(func(app ForegroundApp) {
			access.Lock()
			queued = append(queued, app)
			access.Unlock()
			select {
			case changed <- struct{}{}:
			default:
			}
		})
		if last.PID == 0 {
			if front, err := c.front.get(operation); err == nil {
				last = ForegroundApp{BundleID: front.bundleID, PID: front.pid}
			}
		}
		for operation.Err() == nil {
			select {
			case <-changed:
			case <-operation.Done():
				continue
			}
			access.Lock()
			arrived := queued
			queued = nil
			access.Unlock()
			for _, app := range arrived {
				if app.PID == last.PID {
					continue
				}
				if last.PID != 0 {
					emit(AppEvent{Kind: "background", BundleID: last.BundleID, PID: last.PID, Time: app.At})
				}
				kind := "foreground"
				if app.Launched {
					kind = "launch"
				}
				emit(AppEvent{Kind: kind, BundleID: app.BundleID, PID: app.PID, Time: app.At})
				last = app
			}
		}
		cancel()
		done()
		if err = ctx.Err(); err != nil {
			return err
		}
	}
}
