//go:build darwin && cgo

package phonemcp

import (
	"encoding/json"
	"maps"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice/accessibility"
	"github.com/swipt-automation/swipt/internal/coredevice/apps"
	"github.com/swipt-automation/swipt/internal/deviceserver"
	"github.com/swipt-automation/swipt/internal/log"
)

type point deviceserver.Point

func (p *point) UnmarshalJSON(data []byte) error {
	values, ok := numbers(data, 2)
	if !ok {
		return E.New("expected a point [x, y] of finite numbers")
	}
	*p = point{values[0], values[1]}
	return nil
}

type rect deviceserver.Rect

func (r *rect) UnmarshalJSON(data []byte) error {
	values, ok := numbers(data, 4)
	if !ok {
		return E.New("expected a rectangle [x, y, width, height] of finite numbers")
	}
	if values[2] <= 0 || values[3] <= 0 {
		return E.New("a rectangle needs a positive width and height")
	}
	*r = rect{values[0], values[1], values[2], values[3]}
	return nil
}

func numbers(data []byte, count int) ([]float64, bool) {
	var values []*float64
	if json.Unmarshal(data, &values) != nil || len(values) != count || slices.Contains(values, nil) {
		return nil, false
	}
	return common.Map(values, func(value *float64) float64 { return *value }), true
}

type strict struct {
	value any
}

func (o *strict) UnmarshalJSON(data []byte) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return E.New("expected an options object")
	}
	structType := reflect.TypeOf(o.value).Elem()
	names := make([]string, structType.NumField())
	for index := range names {
		names[index], _, _ = strings.Cut(structType.Field(index).Tag.Get("json"), ",")
	}
	for name, value := range fields {
		index := slices.Index(names, name)
		if index < 0 {
			return E.New("unknown option ", strconv.Quote(name), "; the options are ", strings.Join(names, ", "))
		}
		if string(value) == "null" {
			if numeric(structType.Field(index).Type) {
				return E.New("option ", name, " is null or not a finite number")
			}
			return E.New("option ", name, " is null")
		}
	}
	return json.Unmarshal(data, o.value)
}

type recognizedText struct {
	Text  string     `json:"text"`
	Frame [4]float64 `json:"frame"`
	Point [2]float64 `json:"point"`
}

type touchOptions struct {
	Count  *int     `json:"count"`
	HoldMs *float64 `json:"holdMs"`
}

func (o touchOptions) values() (int, time.Duration, error) {
	if o.Count != nil && *o.Count < 1 {
		return 0, 0, E.New("count must be at least 1")
	}
	hold, err := duration("holdMs", o.HoldMs)
	return common.PtrValueOrDefault(o.Count), hold, err
}

var buttons = map[string]string{
	"pressHome": "home", "openAppSwitcher": "appSwitcher", "pressPower": "power", "pressVolumeUp": "volumeUp",
	"pressVolumeDown": "volumeDown",
}

var operations = append([]string{
	"status", "screen", "find", "elementAt", "screenshot", "recognizeText",
	"tap", "tapPoint", "swipe", "drag", "pinch", "touch", "setText", "pressKey", "perform", "supports",
	"unlock", "apps", "launch", "clipboard", "setClipboard",
	"setLocation", "clearLocation", "logs",
}, slices.Collect(maps.Keys(buttons))...)

type logEntry struct {
	Time    float64 `json:"time"`
	Level   string  `json:"level"`
	Tag     string  `json:"tag,omitempty"`
	Message string  `json:"message"`
}

type actionResult struct {
	Action   string   `json:"action"`
	Target   *element `json:"target,omitempty"`
	Warnings []string `json:"warnings,omitempty"`
}

func (s *Runner) dispatch(current *run, table *elementTable, name string, args []json.RawMessage) (any, error) {
	ctx := current.ctx
	phone := s.phone
	if button, found := buttons[name]; found {
		if err := decode(args, 0); err != nil {
			return nil, err
		}
		return table.act(name)(phone.Button(ctx, button))
	}
	switch name {
	case "status":
		if err := decode(args, 0); err != nil {
			return nil, err
		}
		status, err := phone.Status(ctx)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"name": status.Name, "model": status.Model, "os": status.OSVersion, "build": status.Build,
			"locked": status.Locked, "display": status.Display, "app": status.BundleID, "language": status.Language,
			"screen": map[string]any{
				"width": status.Screen.Width, "height": status.Screen.Height,
				"scale": status.Screen.Scale, "orientation": status.Screen.Orientation,
			},
		}, nil
	case "screen":
		var options struct {
			Raw  bool `json:"raw"`
			Fast bool `json:"fast"`
		}
		if err := decode(args, 0, &strict{&options}); err != nil {
			return nil, err
		}
		var model *deviceserver.PhoneModel
		var err error
		if options.Fast {
			model, err = phone.ReadFront(ctx, nil)
		} else {
			model, err = phone.Read(ctx)
		}
		if err != nil {
			return nil, err
		}
		return table.screen(model, options.Raw), nil
	case "find":
		var fields *[]string
		if err := decode(args, 0, &fields); err != nil {
			return nil, err
		}
		var attributes []int64
		if fields != nil {
			attributes = accessibility.SnapshotAttributes(*fields)
		}
		model, err := phone.ReadFront(ctx, attributes)
		if err != nil {
			return nil, err
		}
		return table.screen(model, true), nil
	case "elementAt":
		var at point
		var options struct {
			Fast bool `json:"fast"`
		}
		if err := decode(args, 1, &at, &strict{&options}); err != nil {
			return nil, err
		}
		if options.Fast {
			hit, err := phone.HitTest(ctx, deviceserver.Point(at))
			if err != nil {
				return nil, err
			}
			return map[string]any{"label": hit.Label, "identifier": hit.Identifier, "value": hit.Value, "listed": false}, nil
		}
		hit, node, err := phone.ElementAt(ctx, deviceserver.Point(at))
		if err != nil {
			return nil, err
		}
		if node != nil {
			return table.describe(node), nil
		}
		return map[string]any{"label": hit.Label, "identifier": hit.Identifier, "value": hit.Value, "listed": false}, nil
	case "screenshot":
		var options struct {
			Region *rect    `json:"region"`
			Scale  *float64 `json:"scale"`
		}
		if err := decode(args, 0, &strict{&options}); err != nil {
			return nil, err
		}
		if options.Scale != nil && *options.Scale <= 0 {
			return nil, E.New("scale must be positive")
		}
		image, err := phone.Screenshot(ctx, (*deviceserver.Rect)(options.Region), common.PtrValueOrDefault(options.Scale))
		if err != nil {
			return nil, err
		}
		if current.logger == nil {
			if err = current.image(image); err != nil {
				return nil, err
			}
		}
		return map[string]any{"width": image.Width, "height": image.Height, "scale": image.Scale, "region": rectArray(image.Region)}, nil
	case "recognizeText":
		var options struct {
			Region   *rect  `json:"region"`
			Language string `json:"language"`
		}
		if err := decode(args, 0, &strict{&options}); err != nil {
			return nil, err
		}
		texts, err := phone.RecognizeText(ctx, (*deviceserver.Rect)(options.Region), options.Language)
		if err != nil {
			return nil, err
		}
		return common.Map(texts, func(text deviceserver.PhoneText) recognizedText {
			return recognizedText{Text: text.Text, Frame: rectArray(text.Frame), Point: pointArray(text.Frame.Center())}
		}), nil
	case "tap":
		var ref int
		var options touchOptions
		if err := decode(args, 1, &ref, &strict{&options}); err != nil {
			return nil, err
		}
		target, err := table.node(ref)
		if err != nil {
			return nil, err
		}
		count, hold, err := options.values()
		if err != nil {
			return nil, err
		}
		return table.act("tap")(phone.TapElement(ctx, target, count, hold))
	case "tapPoint":
		var at point
		var options touchOptions
		if err := decode(args, 1, &at, &strict{&options}); err != nil {
			return nil, err
		}
		count, hold, err := options.values()
		if err != nil {
			return nil, err
		}
		return table.act("tap")(phone.TapPoint(ctx, deviceserver.Point(at), count, hold))
	case "swipe", "drag":
		var from, to point
		var options struct {
			DurationMs *float64 `json:"durationMs"`
			PressMs    *float64 `json:"pressMs"`
		}
		if err := decode(args, 2, &from, &to, &strict{&options}); err != nil {
			return nil, err
		}
		move, err := duration("durationMs", options.DurationMs)
		if err != nil {
			return nil, err
		}
		var fingers [][]deviceserver.TouchSample
		if name == "swipe" {
			if options.PressMs != nil {
				return nil, E.New("pressMs applies to drag")
			}
			fingers, err = deviceserver.SwipePath(deviceserver.Point(from), deviceserver.Point(to), move)
		} else {
			if options.PressMs != nil && *options.PressMs < 0 {
				return nil, E.New("pressMs must not be negative")
			}
			fingers, err = deviceserver.DragPath(deviceserver.Point(from), deviceserver.Point(to), move, milliseconds(common.PtrValueOrDefault(options.PressMs)))
		}
		if err != nil {
			return nil, err
		}
		return table.act(name)(phone.Touch(ctx, fingers))
	case "pinch":
		var center point
		var scale float64
		var options struct {
			DurationMs *float64 `json:"durationMs"`
		}
		if err := decode(args, 2, &center, &scale, &strict{&options}); err != nil {
			return nil, err
		}
		pinch, err := duration("durationMs", options.DurationMs)
		if err != nil {
			return nil, err
		}
		return table.act("pinch")(phone.Pinch(ctx, deviceserver.Point(center), scale, pinch))
	case "touch":
		var fingers [][][3]*float64
		if err := decode(args, 1, &fingers); err != nil {
			return nil, err
		}
		samples := make([][]deviceserver.TouchSample, len(fingers))
		for index, finger := range fingers {
			for _, sample := range finger {
				if slices.Contains(sample[:], nil) {
					return nil, E.New("touch samples need finite numbers [x, y, ms]")
				}
				samples[index] = append(samples[index], deviceserver.TouchSample{X: *sample[0], Y: *sample[1], T: milliseconds(*sample[2])})
			}
		}
		return table.act("touch")(phone.Touch(ctx, samples))
	case "setText":
		var ref int
		var text string
		if err := decode(args, 2, &ref, &text); err != nil {
			return nil, err
		}
		target, err := table.node(ref)
		if err != nil {
			return nil, err
		}
		return table.act("setText")(phone.SetText(ctx, target, text))
	case "pressKey":
		var combo string
		if err := decode(args, 1, &combo); err != nil {
			return nil, err
		}
		return table.act("pressKey")(phone.Key(ctx, combo))
	case "perform", "supports":
		var ref int
		var action string
		if err := decode(args, 2, &ref, &action); err != nil {
			return nil, err
		}
		target, err := table.node(ref)
		if err != nil {
			return nil, err
		}
		if name == "supports" {
			return phone.Supports(ctx, target, action)
		}
		return table.act("perform")(phone.Perform(ctx, target, action))
	case "unlock":
		if err := decode(args, 0); err != nil {
			return nil, err
		}
		return table.act("unlock")(phone.Unlock(ctx))
	case "apps":
		if err := decode(args, 0); err != nil {
			return nil, err
		}
		list, err := phone.Apps(ctx)
		if err != nil {
			return nil, err
		}
		return common.Map(list, func(it apps.App) map[string]string {
			return map[string]string{"name": it.Name, "bundleId": it.BundleID}
		}), nil
	case "launch":
		var bundleID string
		var options struct {
			URL     string `json:"url"`
			Restart bool   `json:"restart"`
		}
		if err := decode(args, 1, &bundleID, &strict{&options}); err != nil {
			return nil, err
		}
		return table.act("launch")(phone.Launch(ctx, bundleID, options.URL, options.Restart, true))
	case "clipboard":
		if err := decode(args, 0); err != nil {
			return nil, err
		}
		text, found, err := phone.Clipboard(ctx)
		if err != nil {
			return nil, err
		}
		if !found {
			return json.RawMessage("null"), nil
		}
		return text, nil
	case "setClipboard":
		if len(args) == 0 {
			return nil, E.New("argument 1 is missing")
		}
		var text *string
		if err := decode(args, 0, &text); err != nil {
			return nil, err
		}
		return nil, phone.SetClipboard(ctx, text)
	case "setLocation":
		var latitude, longitude float64
		if err := decode(args, 2, &latitude, &longitude); err != nil {
			return nil, err
		}
		if latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180 {
			return nil, E.New("the latitude must be within ±90 and the longitude within ±180 degrees")
		}
		if err := phone.SetLocation(ctx, latitude, longitude); err != nil {
			return nil, err
		}
		return actionResult{Action: "setLocation " + strconv.FormatFloat(latitude, 'f', -1, 64) + ", " + strconv.FormatFloat(longitude, 'f', -1, 64)}, nil
	case "clearLocation":
		if err := decode(args, 0); err != nil {
			return nil, err
		}
		if err := phone.ClearLocation(ctx); err != nil {
			return nil, err
		}
		return actionResult{Action: "clearLocation"}, nil
	case "logs":
		var options struct {
			Since float64 `json:"since"`
			Level string  `json:"level"`
		}
		if err := decode(args, 0, &strict{&options}); err != nil {
			return nil, err
		}
		level := log.LevelDebug
		if options.Level != "" {
			var err error
			level, err = log.ParseLevel(options.Level)
			if err != nil {
				return nil, E.New("unknown level ", strconv.Quote(options.Level), "; the levels are debug, info, warn, error")
			}
		}
		return common.Map(s.logFactory.Entries(time.UnixMilli(int64(options.Since)), level), func(entry log.Entry) logEntry {
			return logEntry{
				Time:    float64(entry.Time.UnixMicro()) / 1000,
				Level:   log.FormatLevel(entry.Level),
				Tag:     entry.Tag,
				Message: entry.Message,
			}
		}), nil
	}
	return nil, E.New("unknown operation ", name)
}

func decode(args []json.RawMessage, required int, values ...any) error {
	if len(args) > len(values) {
		return E.New("takes ", len(values), " arguments, not ", len(args))
	}
	for index, value := range values {
		if index >= len(args) || string(args[index]) == "null" {
			if index < required {
				if numeric(reflect.TypeOf(value)) {
					return E.New("argument ", index+1, " is missing or not a finite number")
				}
				return E.New("argument ", index+1, " is missing")
			}
			continue
		}
		if err := json.Unmarshal(args[index], value); err != nil {
			return E.Cause(err, "decode argument ", index+1)
		}
	}
	return nil
}

func numeric(value reflect.Type) bool {
	for value.Kind() == reflect.Pointer {
		value = value.Elem()
	}
	return value.Kind() >= reflect.Int && value.Kind() <= reflect.Float64
}

func duration(name string, value *float64) (time.Duration, error) {
	if value == nil {
		return 0, nil
	}
	if *value <= 0 {
		return 0, E.New(name, " must be positive")
	}
	return milliseconds(*value), nil
}

func milliseconds(value float64) time.Duration {
	return time.Duration(value * float64(time.Millisecond))
}
