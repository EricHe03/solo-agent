package device

import (
	"context"

	"github.com/swipt-automation/swipt/internal/coredevice/screencapture"
)

// The capture service answered a request made while another capture was in
// progress with CoreDeviceError 25003 (iPhone18,2, iOS 27.2).
func (p *Phone) Capture(ctx context.Context) ([]byte, float64, error) {
	c, ctx, done, err := p.begin(ctx)
	if err != nil {
		return nil, 0, err
	}
	defer done()
	geometry, err := c.readGeometry(ctx)
	if err != nil {
		return nil, 0, err
	}
	p.captureAccess.Lock()
	defer p.captureAccess.Unlock()
	data, err := screencapture.Capture(ctx, c.device)
	return data, geometry.Scale, err
}
