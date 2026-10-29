package deviceserver

import (
	"context"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice/instruments"
)

func (p *Phone) closeLocation() {
	if p.location == nil {
		return
	}
	if err := p.location.Close(); err != nil {
		p.logger.Debug(E.Cause(err, "close the location simulation"))
	}
	p.location = nil
}

func (p *Phone) SetLocation(ctx context.Context, latitude, longitude float64) error {
	p.access.Lock()
	defer p.access.Unlock()
	a, ctx, cancel, err := p.begin(ctx)
	if err != nil {
		return err
	}
	defer cancel()
	if p.location != nil && p.location.Err() != nil {
		p.closeLocation()
	}
	if p.location == nil {
		p.location, err = instruments.DialLocation(ctx, a.owner, a.device)
		if err != nil {
			return err
		}
	}
	if err = p.location.Set(ctx, latitude, longitude); err != nil {
		p.closeLocation()
		return err
	}
	return nil
}

func (p *Phone) ClearLocation(ctx context.Context) error {
	p.access.Lock()
	defer p.access.Unlock()
	_, ctx, cancel, err := p.begin(ctx)
	if err != nil {
		return err
	}
	defer cancel()
	if p.location == nil || p.location.Err() != nil {
		p.closeLocation()
		return E.New("no location is simulated")
	}
	err = p.location.Clear(ctx)
	p.closeLocation()
	return err
}
