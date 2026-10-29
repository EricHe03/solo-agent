package instruments

import (
	"context"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice"
	"github.com/swipt-automation/swipt/internal/coredevice/dtx"
)

const (
	appStatesService = "com.apple.instruments.server.services.mobilenotifications"
	appStatesChannel = 1
)

// appName is the executable's name, and execName the bundle's path as the app
// list reports it (iPhone18,2, iOS 27.2 24B115).
type AppState struct {
	Name  string
	Path  string
	PID   uint64
	State string
}

type AppStates struct {
	conn   *dtx.Conn
	states chan AppState
}

func DialAppStates(ctx, owner context.Context, device *coredevice.Device) (*AppStates, error) {
	conn, err := device.DialService(ctx, serviceName)
	if err != nil {
		return nil, E.Cause(err, "instruments: connect")
	}
	a := &AppStates{states: make(chan AppState, 64)}
	dtxConn, err := dtx.NewConn(owner, conn, func(event dtx.Event) (any, bool) {
		if event.Selector == "applicationStateNotification:" && len(event.Arguments) > 0 {
			if fields, ok := event.Arguments[0].(map[string]any); ok {
				state := AppState{}
				state.Name, _ = fields["appName"].(string)
				state.Path, _ = fields["execName"].(string)
				state.State, _ = fields["state_description"].(string)
				switch pid := fields["pid"].(type) {
				case uint64:
					state.PID = pid
				case int64:
					state.PID = uint64(pid)
				}
				select {
				case a.states <- state:
				default:
				}
			}
		}
		return nil, true
	})
	if err != nil {
		conn.Close()
		return nil, E.Cause(err, "instruments: initialize DTX")
	}
	a.conn = dtxConn
	err = dtxConn.Notify(ctx, 0, "_notifyOfPublishedCapabilities:", map[string]any{
		"com.apple.private.DTXBlockCompression": int64(0), "com.apple.private.DTXConnection": int64(1),
	})
	if err != nil {
		dtxConn.Close()
		return nil, E.Cause(err, "instruments: announce capabilities")
	}
	if _, err = dtxConn.Invoke(ctx, 0, "_requestChannelWithCode:identifier:", dtx.Int32(appStatesChannel), appStatesService); err != nil {
		dtxConn.Close()
		return nil, E.Cause(err, "instruments: open ", appStatesService)
	}
	if _, err = dtxConn.Invoke(ctx, appStatesChannel, "setApplicationStateNotificationsEnabled:", true); err != nil {
		dtxConn.Close()
		return nil, E.Cause(err, "instruments: enable application state notifications")
	}
	return a, nil
}

func (a *AppStates) States() <-chan AppState {
	return a.states
}

func (a *AppStates) Done() <-chan struct{} {
	return a.conn.Done()
}

func (a *AppStates) Err() error {
	return a.conn.Err()
}

func (a *AppStates) Close() error {
	return a.conn.Close()
}
