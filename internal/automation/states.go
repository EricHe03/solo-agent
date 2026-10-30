//go:build darwin && cgo

package automation

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/device"
)

func (e *engine) watch(ctx context.Context, kind string, args []json.RawMessage, publish func(any, error)) error {
	call := &operation{engine: e, name: kind, args: args}
	ended := func(err error) {
		if ctx.Err() != nil {
			return
		}
		if errors.Is(err, context.Canceled) {
			err = E.Extend(device.ErrDisconnected, "the connection dropped while watching ", kind)
		}
		publish(nil, err)
	}
	switch kind {
	case "device.state":
		var name string
		if err := call.decode(1, &name); err != nil {
			return err
		}
		phone, err := call.phone()
		if err != nil {
			return err
		}
		switch name {
		case "foreground":
			go func() {
				ended(phone.WatchForeground(ctx, func(app string) { publish(app, nil) }))
			}()
		case "locked", "display":
			go func() {
				ended(phone.WatchState(ctx, name, func(value any) { publish(value, nil) }))
			}()
		default:
			return E.Cause1(ErrInvalid, E.New("unknown state ", strconv.Quote(name)))
		}
		return nil
	case "graphics.watch":
		return e.watchGraphics(ctx, call, publish, ended)
	case "device.appEvents":
		if err := call.decode(0); err != nil {
			return err
		}
		phone, err := call.phone()
		if err != nil {
			return err
		}
		go func() {
			ended(phone.WatchApps(ctx, func(event device.AppEvent) {
				publish(map[string]any{"type": event.Kind, "bundleId": event.BundleID, "pid": event.PID, "time": event.Time.UnixMilli()}, nil)
			}))
		}()
		return nil
	}
	return E.Cause1(ErrInvalid, E.New("unknown subscription ", strconv.Quote(kind)))
}

const locationClearLimit = 10 * time.Second

func (h *Host) ownLocation(id string) {
	h.locationAccess.Lock()
	h.locationOwner = id
	h.locationAccess.Unlock()
}

func (h *Host) releaseLocation(id string) {
	h.locationAccess.Lock()
	owned := h.locationOwner == id
	if owned {
		h.locationOwner = ""
	}
	h.locationAccess.Unlock()
	if !owned || h.options.Device == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), locationClearLimit)
		defer cancel()
		if err := h.options.Device.ClearLocation(ctx); err != nil {
			h.logger.Debug(E.Cause(err, "clear the simulated location"))
		}
	}()
}
