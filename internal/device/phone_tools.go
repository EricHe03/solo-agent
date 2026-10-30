package device

import (
	"context"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice/instruments"
)

func (c *conn) closeLocation() {
	if c.location == nil {
		return
	}
	if err := c.location.Close(); err != nil {
		c.logger.Debug(E.Cause(err, "close the location simulation"))
	}
	c.location = nil
}

func (c *conn) setLocation(ctx context.Context, latitude, longitude float64) error {
	c.locationAccess.Lock()
	defer c.locationAccess.Unlock()
	if c.location != nil && c.location.Err() != nil {
		c.closeLocation()
	}
	if c.location == nil {
		location, err := instruments.DialLocation(ctx, c.owner, c.device)
		if err != nil {
			return err
		}
		c.location = location
	}
	if err := c.location.Set(ctx, latitude, longitude); err != nil {
		c.closeLocation()
		return err
	}
	return nil
}

func (p *Phone) SetLocation(ctx context.Context, latitude, longitude float64) error {
	c, ctx, done, err := p.begin(ctx)
	if err != nil {
		return err
	}
	defer done()
	if err = c.setLocation(ctx, latitude, longitude); err != nil {
		return err
	}
	p.locationAccess.Lock()
	if p.location == nil {
		p.location = &simulatedLocation{release: p.connection.hold()}
	}
	p.location.latitude, p.location.longitude = latitude, longitude
	p.locationAccess.Unlock()
	return nil
}

func (p *Phone) ClearLocation(ctx context.Context) error {
	p.locationAccess.Lock()
	simulated := p.location
	p.location = nil
	p.locationAccess.Unlock()
	if simulated == nil {
		return E.New("no location is simulated")
	}
	defer simulated.release()
	c, ctx, done, err := p.begin(ctx)
	if err != nil {
		return err
	}
	defer done()
	c.locationAccess.Lock()
	defer c.locationAccess.Unlock()
	if c.location == nil || c.location.Err() != nil {
		c.closeLocation()
		return nil
	}
	err = c.location.Clear(ctx)
	c.closeLocation()
	return err
}

func (p *Phone) attached(c *conn) {
	p.locationAccess.Lock()
	simulated := p.location
	var latitude, longitude float64
	if simulated != nil {
		latitude, longitude = simulated.latitude, simulated.longitude
	}
	p.locationAccess.Unlock()
	if simulated == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(c.ctx, 30*time.Second)
		defer cancel()
		if err := c.setLocation(ctx, latitude, longitude); err != nil && c.ctx.Err() == nil {
			p.logger.Warn(E.Cause(err, "simulate the location again after reconnecting"))
		}
	}()
}
