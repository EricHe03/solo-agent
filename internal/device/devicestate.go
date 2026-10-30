package device

import (
	"context"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

// The remote notification proxy relays any Darwin notification it is asked to
// observe, such as com.apple.system.config.network_change (iPhone18,2, iOS
// 27.2 24B115).
const notificationProxyService = "com.apple.mobile.notification_proxy.shim.remote"

var stateNotifications = []string{
	"com.apple.springboard.lockstate",
	"com.apple.springboard.hasBlankedScreen",
	"com.apple.iokit.hid.displayStatus",
}

const (
	lockedPoll  = 5 * time.Second
	displayPoll = time.Second
)

type darwinNotifications struct {
	conn *conn

	access   sync.Mutex
	watchers map[chan struct{}]struct{}
	relayed  bool
	stop     context.CancelFunc
	stopped  chan struct{}
}

func newDarwinNotifications(c *conn) *darwinNotifications {
	return &darwinNotifications{conn: c, watchers: make(map[chan struct{}]struct{})}
}

func (d *darwinNotifications) watch() (changed <-chan struct{}, relayed func() bool, cancel func()) {
	signal := make(chan struct{}, 1)
	d.access.Lock()
	d.watchers[signal] = struct{}{}
	if d.stop == nil {
		ctx, stop := context.WithCancel(d.conn.ctx)
		d.stop, d.stopped = stop, make(chan struct{})
		go d.observe(ctx, d.stopped)
	}
	d.access.Unlock()
	var once sync.Once
	return signal, func() bool {
			d.access.Lock()
			defer d.access.Unlock()
			return d.relayed
		}, func() {
			once.Do(func() {
				d.access.Lock()
				defer d.access.Unlock()
				delete(d.watchers, signal)
				if len(d.watchers) == 0 && d.stop != nil {
					d.stop()
					d.stop, d.relayed = nil, false
				}
			})
		}
}

func (d *darwinNotifications) observe(ctx context.Context, stopped chan struct{}) {
	defer close(stopped)
	err := d.relay(ctx)
	d.access.Lock()
	d.relayed = false
	d.access.Unlock()
	if err != nil && ctx.Err() == nil {
		d.conn.logger.Debug(E.Cause(err, "observe the device's lock and display notifications"))
	}
}

func (d *darwinNotifications) relay(ctx context.Context) error {
	conn, err := d.conn.device.DialShim(ctx, notificationProxyService)
	if err != nil {
		return err
	}
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	defer conn.Close()
	for _, name := range stateNotifications {
		if err = conn.Send(map[string]any{"Command": "ObserveNotification", "Name": name}); err != nil {
			return E.Cause(err, "observe ", name)
		}
	}
	d.access.Lock()
	d.relayed = true
	d.access.Unlock()
	for {
		message, err := conn.Receive()
		if err != nil {
			return err
		}
		switch message["Command"] {
		case "RelayNotification":
			name, _ := message["Name"].(string)
			d.conn.events.publish(Event{Kind: EventDevice, Name: name})
			d.access.Lock()
			for signal := range d.watchers {
				select {
				case signal <- struct{}{}:
				default:
				}
			}
			d.access.Unlock()
		case "ProxyDeath":
			return E.New("the notification proxy stopped")
		}
	}
}

func (d *darwinNotifications) close() {
	d.access.Lock()
	stop, stopped := d.stop, d.stopped
	d.stop = nil
	d.access.Unlock()
	if stop != nil {
		stop()
		<-stopped
	}
}

func (p *Phone) WatchState(ctx context.Context, name string, emit func(any)) error {
	read := func(ctx context.Context, c *conn) (any, error) {
		if name == "locked" {
			locked, err := c.lockState.locked(ctx, c.device)
			if err != nil {
				return nil, E.Cause(err, "read the lock state")
			}
			return locked, nil
		}
		return p.backlight(ctx, c)
	}
	poll := displayPoll
	if name == "locked" {
		poll = lockedPoll
	}
	var last any
	first := true
	for {
		c, release, err := p.connection.acquire(ctx)
		if err != nil {
			return err
		}
		changed, relayed, cancel := c.darwin.watch()
		operation, stop := c.operation(ctx)
		for operation.Err() == nil {
			value, err := read(operation, c)
			switch {
			case err != nil && operation.Err() == nil:
				p.logger.Debug(E.Cause(err, "read ", name))
			case err == nil && (first || value != last):
				first, last = false, value
				emit(value)
			}
			wait := poll
			if !relayed() {
				wait = displayPoll
			}
			timer := time.NewTimer(wait)
			select {
			case <-changed:
			case <-timer.C:
			case <-operation.Done():
			}
			timer.Stop()
		}
		stop()
		cancel()
		release()
		if err = ctx.Err(); err != nil {
			return err
		}
	}
}
