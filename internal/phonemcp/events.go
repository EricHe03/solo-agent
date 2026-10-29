//go:build darwin && cgo

package phonemcp

import (
	"context"
	"encoding/json"
	"maps"
	"slices"
	"strconv"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/deviceserver"
	"github.com/swipt-automation/swipt/internal/jsc"
)

const eventBacklog = 16

type phoneEvent struct {
	name    string
	payload any
}

type foregroundEvent struct {
	App  string `json:"app"`
	PID  uint64 `json:"pid"`
	Time int64  `json:"time"`
}

type foregroundHub struct {
	ctx       context.Context
	phone     *deviceserver.Phone
	access    sync.Mutex
	listeners map[chan phoneEvent]struct{}
	stop      context.CancelFunc
}

func (h *foregroundHub) add(events chan phoneEvent) {
	h.access.Lock()
	defer h.access.Unlock()
	h.listeners[events] = struct{}{}
	if h.stop != nil {
		return
	}
	ctx, stop := context.WithCancel(h.ctx)
	h.stop = stop
	go h.phone.WatchForeground(ctx, func(app deviceserver.ForegroundApp) {
		event := phoneEvent{name: "foreground", payload: foregroundEvent{App: app.BundleID, PID: app.PID, Time: time.Now().UnixMilli()}}
		h.access.Lock()
		defer h.access.Unlock()
		for listener := range h.listeners {
			select {
			case listener <- event:
			default:
			}
		}
	})
}

func (h *foregroundHub) remove(events chan phoneEvent) {
	h.access.Lock()
	defer h.access.Unlock()
	delete(h.listeners, events)
	if len(h.listeners) == 0 && h.stop != nil {
		h.stop()
		h.stop = nil
	}
}

func (e *engine) pending() bool {
	return len(e.timers) > 0 || len(e.subscriptions) > 0
}

func (e *engine) subscribe(arguments []jsc.Value) (any, error) {
	values, err := texts(arguments, 1)
	if err != nil {
		return nil, err
	}
	if values[0] != "foreground" {
		return nil, E.New("unknown event ", strconv.Quote(values[0]), "; the events are foreground")
	}
	if len(e.subscriptions) == 0 {
		for len(e.events) > 0 {
			<-e.events
		}
		e.runner.foreground.add(e.events)
	}
	e.sequence++
	e.subscriptions[e.sequence] = values[0]
	return e.sequence, nil
}

func (e *engine) unsubscribe(arguments []jsc.Value) (any, error) {
	if len(arguments) == 0 {
		return nil, nil
	}
	id := int(arguments[0].Number())
	if _, found := e.subscriptions[id]; !found {
		return nil, nil
	}
	delete(e.subscriptions, id)
	if len(e.subscriptions) == 0 {
		e.runner.foreground.remove(e.events)
	}
	return nil, nil
}

func (e *engine) dispatchEvent(event phoneEvent) error {
	ids := slices.Sorted(maps.Keys(e.subscriptions))
	ids = slices.DeleteFunc(ids, func(id int) bool { return e.subscriptions[id] != event.name })
	if len(ids) == 0 {
		return nil
	}
	encodedIDs, err := json.Marshal(ids)
	if err != nil {
		return err
	}
	payload, err := json.Marshal(event.payload)
	if err != nil {
		return err
	}
	idsValue := e.context.NewString(string(encodedIDs))
	defer idsValue.Release()
	payloadValue := e.context.NewString(string(payload))
	defer payloadValue.Release()
	result, err := e.deliver.Call(idsValue, payloadValue)
	if err != nil {
		return err
	}
	result.Release()
	return nil
}
