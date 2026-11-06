package libSwipt

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"strings"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/device"
)

const (
	agentDefaultActionTimeout = 20 * time.Second
	agentMaximumTimeout       = 2 * time.Minute
	agentDefaultElementWait   = 3 * time.Second
)

// AgentToolCall is a cancellable, typed device operation. It deliberately does
// not expose the JavaScript automation runtime to AI-generated input.
type AgentToolCall struct {
	cancel context.CancelFunc
	run    func() (string, error)
}

func (p *Platform) NewAgentToolCall(name, input string, timeoutMs int32) *AgentToolCall {
	timeout := time.Duration(timeoutMs) * time.Millisecond
	if timeoutMs == 0 {
		timeout = agentDefaultActionTimeout
	}
	if timeout < 0 || timeout > agentMaximumTimeout {
		timeout = agentMaximumTimeout
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	call := &AgentToolCall{cancel: cancel}
	call.run = func() (string, error) {
		defer cancel()
		result, err := p.executeAgentTool(ctx, name, []byte(input))
		if err != nil {
			return "", err
		}
		encoded, err := json.Marshal(result)
		if err != nil {
			return "", E.Cause(err, "encode agent tool result")
		}
		return string(encoded), nil
	}
	return call
}

func (c *AgentToolCall) Run() (string, error) {
	return c.run()
}

func (c *AgentToolCall) Cancel() {
	c.cancel()
}

func decodeAgentInput(data []byte, output any) error {
	if len(bytes.TrimSpace(data)) == 0 {
		data = []byte("{}")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(output); err != nil {
		return E.Cause1(device.ErrInvalid, E.Cause(err, "invalid tool input"))
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return E.Cause1(device.ErrInvalid, E.New("tool input must contain one JSON object"))
	}
	return nil
}

func finite(values ...float64) bool {
	for _, value := range values {
		if math.IsNaN(value) || math.IsInf(value, 0) {
			return false
		}
	}
	return true
}

func elementWait(milliseconds float64) (time.Duration, error) {
	if milliseconds == 0 {
		return agentDefaultElementWait, nil
	}
	if !finite(milliseconds) || milliseconds < 0 || milliseconds > 30_000 {
		return 0, E.Cause1(device.ErrInvalid, E.New("timeoutMs must be between 0 and 30000"))
	}
	return time.Duration(milliseconds) * time.Millisecond, nil
}

func (p *Platform) executeAgentTool(ctx context.Context, name string, input []byte) (any, error) {
	phone := p.device.connection.Phone()
	switch name {
	case "get_device_info":
		var options struct{}
		if err := decodeAgentInput(input, &options); err != nil {
			return nil, err
		}
		info, err := phone.Info(ctx)
		if err != nil {
			return nil, err
		}
		locked, err := phone.Locked(ctx)
		if err != nil {
			return nil, err
		}
		display, err := phone.Display(ctx)
		if err != nil {
			return nil, err
		}
		return map[string]any{"name": info.Name, "model": info.Model, "osVersion": info.OSVersion, "build": info.Build, "language": info.Language, "screen": info.Screen, "locked": locked, "display": display}, nil
	case "get_foreground_app":
		var options struct{}
		if err := decodeAgentInput(input, &options); err != nil {
			return nil, err
		}
		bundleID, err := phone.Frontmost(ctx)
		if err != nil {
			return nil, err
		}
		return map[string]any{"bundleId": bundleID}, nil
	case "get_accessibility_tree":
		var options struct {
			Scope string `json:"scope"`
			Full  bool   `json:"full"`
		}
		if err := decodeAgentInput(input, &options); err != nil {
			return nil, err
		}
		if options.Scope != "" && options.Scope != "frontApp" && options.Scope != "screen" {
			return nil, E.Cause1(device.ErrInvalid, E.New("scope must be frontApp or screen"))
		}
		view, err := phone.Snapshot(ctx, device.SnapshotOptions{Front: options.Scope != "screen", Raw: options.Full})
		if err != nil {
			return nil, err
		}
		return view, nil
	case "take_screenshot":
		var options struct{}
		if err := decodeAgentInput(input, &options); err != nil {
			return nil, err
		}
		capture, scale, err := phone.Capture(ctx)
		if err != nil {
			return nil, err
		}
		return map[string]any{"mimeType": "image/png", "scale": scale, "dataBase64": base64.StdEncoding.EncodeToString(capture)}, nil
	case "launch_app":
		var options struct {
			BundleID string `json:"bundleId"`
			URL      string `json:"url"`
		}
		if err := decodeAgentInput(input, &options); err != nil {
			return nil, err
		}
		if options.BundleID == "" || len(options.BundleID) > 255 {
			return nil, E.Cause1(device.ErrInvalid, E.New("bundleId is required and must not exceed 255 characters"))
		}
		if len(options.URL) > 4096 {
			return nil, E.Cause1(device.ErrInvalid, E.New("url must not exceed 4096 characters"))
		}
		if err := phone.Launch(ctx, options.BundleID, options.URL, false, true); err != nil {
			return nil, err
		}
		return map[string]any{"launched": options.BundleID}, nil
	case "tap_element":
		var options struct {
			Ref       string  `json:"ref"`
			TimeoutMS float64 `json:"timeoutMs"`
		}
		if err := decodeAgentInput(input, &options); err != nil {
			return nil, err
		}
		if options.Ref == "" {
			return nil, E.Cause1(device.ErrInvalid, E.New("ref is required"))
		}
		wait, err := elementWait(options.TimeoutMS)
		if err != nil {
			return nil, err
		}
		aim, err := phone.Tap(ctx, options.Ref, wait)
		if err != nil {
			return nil, err
		}
		return map[string]any{"element": aim.Element, "point": aim.Point}, nil
	case "tap_coordinates":
		var options struct {
			X     float64 `json:"x"`
			Y     float64 `json:"y"`
			Count int     `json:"count"`
		}
		if err := decodeAgentInput(input, &options); err != nil {
			return nil, err
		}
		if !finite(options.X, options.Y) || options.Count < 0 || options.Count > 2 {
			return nil, E.Cause1(device.ErrInvalid, E.New("x and y must be finite and count must be 1 or 2"))
		}
		if options.Count == 0 {
			options.Count = 1
		}
		at := device.Point{X: options.X, Y: options.Y}
		if err := phone.TapPoint(ctx, at, options.Count); err != nil {
			return nil, err
		}
		return map[string]any{"point": at}, nil
	case "swipe":
		var options struct {
			FromX      float64 `json:"fromX"`
			FromY      float64 `json:"fromY"`
			ToX        float64 `json:"toX"`
			ToY        float64 `json:"toY"`
			DurationMS float64 `json:"durationMs"`
		}
		if err := decodeAgentInput(input, &options); err != nil {
			return nil, err
		}
		if !finite(options.FromX, options.FromY, options.ToX, options.ToY, options.DurationMS) || options.DurationMS < 0 || options.DurationMS > 10_000 {
			return nil, E.Cause1(device.ErrInvalid, E.New("coordinates must be finite and durationMs must be between 0 and 10000"))
		}
		path, err := device.SwipePath(device.Point{X: options.FromX, Y: options.FromY}, device.Point{X: options.ToX, Y: options.ToY}, time.Duration(options.DurationMS)*time.Millisecond)
		if err != nil {
			return nil, err
		}
		if err = phone.Touch(ctx, path); err != nil {
			return nil, err
		}
		return map[string]any{"completed": true}, nil
	case "type_text":
		var options struct {
			Ref       string  `json:"ref"`
			Text      string  `json:"text"`
			TimeoutMS float64 `json:"timeoutMs"`
			Submit    bool    `json:"submit"`
		}
		if err := decodeAgentInput(input, &options); err != nil {
			return nil, err
		}
		if options.Ref == "" || len(options.Text) > 16_384 {
			return nil, E.Cause1(device.ErrInvalid, E.New("ref is required and text must not exceed 16384 bytes"))
		}
		wait, err := elementWait(options.TimeoutMS)
		if err != nil {
			return nil, err
		}
		aim, err := phone.SetText(ctx, options.Ref, options.Text, wait)
		if err != nil {
			return nil, err
		}
		if options.Submit {
			if err = phone.Key(ctx, "return"); err != nil {
				return nil, E.Cause(err, "text was entered but Return could not be pressed")
			}
		}
		return map[string]any{"element": aim.Element, "submitted": options.Submit}, nil
	case "press_home":
		var options struct{}
		if err := decodeAgentInput(input, &options); err != nil {
			return nil, err
		}
		if err := phone.Button(ctx, "home"); err != nil {
			return nil, err
		}
		return map[string]any{"completed": true}, nil
	case "press_back":
		var options struct {
			Ref string `json:"ref"`
		}
		if err := decodeAgentInput(input, &options); err != nil {
			return nil, err
		}
		ref := options.Ref
		if ref == "" {
			view, err := phone.Snapshot(ctx, device.SnapshotOptions{Front: true})
			if err != nil {
				return nil, err
			}
			ref = view.Root.Ref
		}
		aim, err := phone.Perform(ctx, ref, "escape")
		if err != nil {
			return nil, E.Cause(err, "iOS has no global Back button; the foreground application's accessibility Escape action was attempted")
		}
		return map[string]any{"element": aim.Element, "action": "escape"}, nil
	case "wait_for_screen":
		var options struct {
			BundleID  string  `json:"bundleId"`
			Text      string  `json:"text"`
			TimeoutMS float64 `json:"timeoutMs"`
		}
		if err := decodeAgentInput(input, &options); err != nil {
			return nil, err
		}
		if options.BundleID == "" && options.Text == "" {
			return nil, E.Cause1(device.ErrInvalid, E.New("bundleId or text is required"))
		}
		if !finite(options.TimeoutMS) || options.TimeoutMS < 0 || options.TimeoutMS > 60_000 {
			return nil, E.Cause1(device.ErrInvalid, E.New("timeoutMs must be between 0 and 60000"))
		}
		if options.TimeoutMS == 0 {
			options.TimeoutMS = 10_000
		}
		deadline := time.Now().Add(time.Duration(options.TimeoutMS) * time.Millisecond)
		for {
			view, err := phone.Snapshot(ctx, device.SnapshotOptions{Front: options.BundleID == ""})
			if err == nil {
				bundleMatches := options.BundleID == "" || view.App == options.BundleID
				textMatches := options.Text == "" || viewContainsText(view, options.Text)
				if bundleMatches && textMatches {
					return view, nil
				}
			}
			if time.Now().After(deadline) {
				if err != nil {
					return nil, err
				}
				return nil, E.Extend(device.ErrTimeout, "the expected screen did not appear; last foreground app was ", view.App)
			}
			if err = sleepAgent(ctx, time.Now().Add(350*time.Millisecond).After(deadline), deadline); err != nil {
				return nil, err
			}
		}
	default:
		return nil, E.Cause1(device.ErrInvalid, E.New("unsupported agent tool ", fmt.Sprintf("%q", name)))
	}
}

func sleepAgent(ctx context.Context, pastDeadline bool, deadline time.Time) error {
	delay := 350 * time.Millisecond
	if pastDeadline {
		delay = max(time.Millisecond, time.Until(deadline))
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func viewContainsText(view *device.View, wanted string) bool {
	wanted = strings.ToLower(wanted)
	var visit func(*device.ViewElement) bool
	visit = func(element *device.ViewElement) bool {
		if element == nil {
			return false
		}
		for _, candidate := range []string{element.Label, element.Value, element.Identifier, element.Placeholder} {
			if strings.Contains(strings.ToLower(candidate), wanted) {
				return true
			}
		}
		for _, child := range element.Children {
			if visit(child) {
				return true
			}
		}
		return false
	}
	return visit(view.Root) || visit(view.System)
}
