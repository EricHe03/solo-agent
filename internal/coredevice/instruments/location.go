package instruments

import (
	"context"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice"
	"github.com/swipt-automation/swipt/internal/coredevice/dtx"
)

const (
	serviceName     = "com.apple.instruments.dtservicehub"
	locationService = "com.apple.instruments.server.services.LocationSimulation"
	// pymobiledevice3 requests channels with codes counting up from 1
	// (pymobiledevice3 cae0191, pymobiledevice3/dtx/connection.py:84, 274-285).
	locationChannel = 1
)

// pymobiledevice3 sends simulateLocationWithLatitude:longitude: asking for a
// reply and stopLocationSimulation without one, and keeps the connection that
// set a location open for as long as the location is to be simulated
// (pymobiledevice3 cae0191,
// pymobiledevice3/services/dvt/instruments/location_simulation.py:7-14,
// pymobiledevice3/cli/developer/dvt/simulate_location.py:36-38).
type Location struct {
	conn *dtx.Conn
}

func DialLocation(ctx, owner context.Context, device *coredevice.Device) (*Location, error) {
	conn, err := device.DialService(ctx, serviceName)
	if err != nil {
		return nil, E.Cause(err, "instruments: connect")
	}
	dtxConn, err := dtx.NewConn(owner, conn, func(dtx.Event) (any, bool) {
		return nil, true
	})
	if err != nil {
		conn.Close()
		return nil, E.Cause(err, "instruments: initialize DTX")
	}
	// pymobiledevice3 announces these capabilities without asking for a reply
	// (pymobiledevice3 cae0191, pymobiledevice3/dtx/connection.py:59-62,
	// pymobiledevice3/dtx/service.py:530-532).
	err = dtxConn.Notify(ctx, 0, "_notifyOfPublishedCapabilities:", map[string]any{
		"com.apple.private.DTXBlockCompression": int64(0), "com.apple.private.DTXConnection": int64(1),
	})
	if err != nil {
		dtxConn.Close()
		return nil, E.Cause(err, "instruments: announce capabilities")
	}
	if _, err = dtxConn.Invoke(ctx, 0, "_requestChannelWithCode:identifier:", dtx.Int32(locationChannel), locationService); err != nil {
		dtxConn.Close()
		return nil, E.Cause(err, "instruments: open ", locationService)
	}
	return &Location{conn: dtxConn}, nil
}

func (l *Location) Set(ctx context.Context, latitude, longitude float64) error {
	_, err := l.conn.Invoke(ctx, locationChannel, "simulateLocationWithLatitude:longitude:", latitude, longitude)
	return err
}

func (l *Location) Clear(ctx context.Context) error {
	return l.conn.Notify(ctx, locationChannel, "stopLocationSimulation")
}

func (l *Location) Close() error {
	return l.conn.Close()
}

func (l *Location) Err() error {
	return l.conn.Err()
}
