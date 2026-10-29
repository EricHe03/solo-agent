//go:build darwin && cgo

package deviceserver

import (
	"bytes"
	"context"
	"image"
	"image/png"
	"slices"
	"strconv"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/vision"
)

type PhoneText struct {
	Text  string
	Frame Rect
}

func (p *Phone) RecognizeText(ctx context.Context, region *Rect, language string) ([]PhoneText, error) {
	if language == "" {
		var err error
		if language, err = p.language(ctx); err != nil {
			return nil, err
		}
	} else {
		supported, err := vision.SupportedLanguages()
		if err != nil {
			return nil, err
		}
		if !slices.Contains(supported, language) {
			return nil, E.New("unknown language ", strconv.Quote(language), "; the languages are ", strings.Join(supported, ", "))
		}
	}
	data, scale, err := p.Capture(ctx)
	if err != nil {
		return nil, err
	}
	config, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, E.Cause(err, "decode the screenshot")
	}
	crop, err := pixelRegion(image.Rect(0, 0, config.Width, config.Height), scale, region)
	if err != nil {
		return nil, err
	}
	texts, err := vision.RecognizeText(ctx, data, language)
	if err != nil {
		return nil, err
	}
	area := Rect{float64(crop.Min.X) / scale, float64(crop.Min.Y) / scale, float64(crop.Dx()) / scale, float64(crop.Dy()) / scale}
	var out []PhoneText
	for _, text := range texts {
		frame := Rect{text.X / scale, text.Y / scale, text.Width / scale, text.Height / scale}
		if !frame.Intersect(area).Empty() {
			out = append(out, PhoneText{Text: text.String, Frame: frame})
		}
	}
	return out, nil
}

func (p *Phone) language(ctx context.Context) (string, error) {
	p.access.Lock()
	defer p.access.Unlock()
	a, ctx, cancel, err := p.begin(ctx)
	if err != nil {
		return "", err
	}
	defer cancel()
	return a.device.Language(ctx)
}
