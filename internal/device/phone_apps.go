package device

import (
	"context"

	"github.com/swipt-automation/swipt/internal/coredevice/apps"
	"github.com/swipt-automation/swipt/internal/coredevice/springboard"
)

func (p *Phone) Apps(ctx context.Context) ([]apps.App, error) {
	c, ctx, done, err := p.begin(ctx)
	if err != nil {
		return nil, err
	}
	defer done()
	return apps.List(ctx, c.device)
}

func (p *Phone) AppIcon(ctx context.Context, bundleID string) ([]byte, error) {
	c, ctx, done, err := p.begin(ctx)
	if err != nil {
		return nil, err
	}
	defer done()
	return springboard.IconPNG(ctx, c.device, bundleID)
}
