//go:build darwin && cgo

package phonemcp

import (
	"context"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/jsc"
)

//go:embed dialog.js
var dialogSource string

//go:embed dialog.d.ts
var dialogDeclarations string

const (
	springBoard   = "com.apple.springboard"
	returnTimeout = 30 * time.Second
)

var ErrDismissed = E.New("the person dismissed the dialog")

type Dialog struct {
	App      string
	InApp    bool
	Ask      func(ctx context.Context, request string) (string, error)
	Backdrop func(image []byte)
}

func (e *engine) newDialog(exports jsc.Value) (jsc.Value, error) {
	host := e.context.NewObject()
	defer host.Release()
	ask := func(inApp bool) jsc.Function {
		return func(arguments []jsc.Value) (any, error) {
			current := e.run
			dialog := current.dialog
			if dialog.Ask == nil {
				return nil, E.New("this server runs on a computer, so it can't show dialogs on the device")
			}
			request, err := arguments[0].JSON()
			if err != nil {
				return nil, err
			}
			if dialog.App != "" && (dialog.InApp || inApp) {
				if err = e.bringForward(current, dialog.App, true); err != nil {
					return nil, err
				}
			}
			answer, err := dialog.Ask(current.ctx, request)
			if errors.Is(err, ErrDismissed) {
				current.stop(err)
			}
			if err != nil {
				if current.ctx.Err() != nil {
					return nil, current.stopped()
				}
				return nil, err
			}
			return json.RawMessage(answer), nil
		}
	}
	host.SetFunction("ask", ask(false))
	host.SetFunction("askInApp", ask(true))
	host.SetFunction("stay", func([]jsc.Value) (any, error) {
		current := e.run
		if app := current.dialog.App; app != "" {
			if err := e.bringForward(current, app, false); err != nil {
				return nil, err
			}
		}
		if e.returnTo != "" && current.dialog.Backdrop != nil {
			current.dialog.Backdrop(nil)
		}
		e.returnTo = ""
		return nil, nil
	})
	host.SetFunction("bytes", func(arguments []jsc.Value) (any, error) {
		text, err := arguments[0].ToString()
		if err != nil {
			return nil, err
		}
		data, err := base64.StdEncoding.DecodeString(text)
		if err != nil {
			return nil, E.Cause(err, "decode the file")
		}
		return jsc.Bytes(data), nil
	})
	factory, err := e.context.Evaluate(dialogSource, "dialog.js")
	if err != nil {
		return jsc.Value{}, err
	}
	defer factory.Release()
	return factory.Call(host, exports)
}

func (e *engine) bringForward(current *run, app string, backdrop bool) error {
	if e.returnTo != "" {
		return nil
	}
	phone := e.runner.phone
	status, err := phone.Status(current.ctx)
	if err != nil {
		return E.Cause(err, "find the app in front")
	}
	if status.BundleID == app {
		return nil
	}
	show := current.dialog.Backdrop
	if !backdrop {
		show = nil
	}
	if show != nil {
		image, _, err := phone.Capture(current.ctx)
		if err != nil {
			return E.Cause(err, "capture the screen")
		}
		show(image)
		// The app shows the snapshot it was suspended with for a frame when it
		// comes back unless the new one, of the backdrop, is in by then
		// (iPhone18,2, iOS 27.2 24B115).
		select {
		case <-time.After(400 * time.Millisecond):
		case <-current.ctx.Done():
			show(nil)
			return current.stopped()
		}
	}
	if _, err = phone.Launch(current.ctx, app, "", false, false); err != nil {
		if show != nil {
			show(nil)
		}
		return E.Cause(err, "bring the app to the front")
	}
	e.returnTo = status.BundleID
	return nil
}

func (e *engine) giveWay(ctx context.Context) error {
	app := e.returnTo
	if app == "" {
		return nil
	}
	e.returnTo = ""
	var err error
	if app == springBoard {
		_, err = e.runner.phone.Button(ctx, "home")
	} else {
		_, err = e.runner.phone.Launch(ctx, app, "", false, false)
	}
	if err != nil {
		return E.Cause(err, "return to ", app)
	}
	return nil
}
