package deviceserver

import (
	"bytes"
	"context"
	"image"
	"image/png"
	"math"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice/screencapture"
	"golang.org/x/image/draw"
)

type PhoneImage struct {
	Data          []byte
	Width, Height int
	Scale         float64
	Region        Rect
}

func (p *Phone) Capture(ctx context.Context) ([]byte, float64, error) {
	p.access.Lock()
	defer p.access.Unlock()
	a, ctx, cancel, err := p.begin(ctx)
	if err != nil {
		return nil, 0, err
	}
	defer cancel()
	geometry, err := p.readGeometry(ctx, a)
	if err != nil {
		return nil, 0, err
	}
	data, err := screencapture.Capture(ctx, a.device)
	return data, geometry.Scale, err
}

func pixelRegion(bounds image.Rectangle, scale float64, region *Rect) (image.Rectangle, error) {
	if region == nil {
		return bounds, nil
	}
	crop := image.Rect(
		int(math.Floor(region.X*scale)), int(math.Floor(region.Y*scale)),
		int(math.Ceil((region.X+region.Width)*scale)), int(math.Ceil((region.Y+region.Height)*scale)),
	).Intersect(bounds)
	if crop.Empty() {
		return image.Rectangle{}, E.New("the region lies outside the screen")
	}
	return crop, nil
}

// Claude Code scales an image down when a side is over 2000 pixels or, for the
// models that set a tile limit, when it covers over 4784 tiles of 28x28
// pixels, and re-encodes one over 512,000 bytes as JPEG (Claude Code 2.1.310
// claude xR 0xcee5319, TTt 0xcee52c9, ld 0xd6acf5c, JS 0xd66d1fa). A 921x2000
// PNG of Settings took 229 KB, while the device sent a 1320x2868 PNG of 4.2 MB
// for the lock screen (iPhone18,2, iOS 27.2 24B115).
const (
	imageSideLimit = 2000
	imageTile      = 28
	imageTileLimit = 4784
)

func imageFits(width, height int) bool {
	tiles := (width + imageTile - 1) / imageTile * ((height + imageTile - 1) / imageTile)
	return max(width, height) <= imageSideLimit && tiles <= imageTileLimit
}

func (p *Phone) Screenshot(ctx context.Context, region *Rect, scale float64) (PhoneImage, error) {
	data, deviceScale, err := p.Capture(ctx)
	if err != nil {
		return PhoneImage{}, err
	}
	source, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return PhoneImage{}, E.Cause(err, "decode the screenshot")
	}
	crop, err := pixelRegion(source.Bounds(), deviceScale, region)
	if err != nil {
		return PhoneImage{}, err
	}
	out := PhoneImage{
		Region: Rect{float64(crop.Min.X) / deviceScale, float64(crop.Min.Y) / deviceScale, float64(crop.Dx()) / deviceScale, float64(crop.Dy()) / deviceScale},
	}
	resize := func() {
		out.Width = max(int(math.Round(out.Region.Width*out.Scale)), 1)
		out.Height = max(int(math.Round(out.Region.Height*out.Scale)), 1)
	}
	switch {
	case scale > deviceScale:
		return PhoneImage{}, E.New("the scale can be at most the screen's ", deviceScale)
	case scale > 0:
		out.Scale = scale
		resize()
		if !imageFits(out.Width, out.Height) {
			return PhoneImage{}, E.New("the image would be ", out.Width, "x", out.Height, " pixels, over ", imageSideLimit, " on its longer side or ", imageTileLimit, " tiles of ", imageTile, "x", imageTile, "; use a smaller scale or region")
		}
	default:
		out.Scale = min(deviceScale, imageSideLimit/max(out.Region.Width, out.Region.Height))
		for resize(); !imageFits(out.Width, out.Height); resize() {
			out.Scale *= 0.99
		}
	}
	target := image.NewRGBA(image.Rect(0, 0, out.Width, out.Height))
	draw.BiLinear.Scale(target, target.Bounds(), source, crop, draw.Src, nil)
	var buffer bytes.Buffer
	if err = png.Encode(&buffer, target); err != nil {
		return PhoneImage{}, E.Cause(err, "encode the screenshot")
	}
	out.Data = buffer.Bytes()
	return out, nil
}
