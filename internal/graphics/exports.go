//go:build darwin && cgo

package graphics

/*
#include <stdlib.h>
#include "graphics.h"
*/
import "C"

import (
	"encoding/json"
	"runtime/cgo"
	"time"

	"github.com/swipt-automation/swipt/internal/automation"
)

type scope struct {
	call    *automation.GraphicsCall
	publish func(any)
}

func scopeOf(handle C.uintptr_t) *scope {
	return cgo.Handle(handle).Value().(*scope)
}

//export swiptGraphicsRelease
func swiptGraphicsRelease(handle C.uintptr_t) {
	cgo.Handle(handle).Delete()
}

//export swiptGraphicsCancelled
func swiptGraphicsCancelled(handle C.uintptr_t) C.bool {
	return C.bool(scopeOf(handle).call.Context().Err() != nil)
}

//export swiptGraphicsTracing
func swiptGraphicsTracing(handle C.uintptr_t) C.bool {
	return C.bool(scopeOf(handle).call.Tracing())
}

//export swiptGraphicsTrace
func swiptGraphicsTrace(handle C.uintptr_t, name *C.char, detail *C.char, startedMs C.double, durationMs C.double) {
	scopeOf(handle).call.Trace(time.UnixMilli(int64(startedMs)), C.GoString(name), C.GoString(detail), time.Duration(float64(durationMs)*float64(time.Millisecond)))
}

//export swiptGraphicsAuthorize
func swiptGraphicsAuthorize(handle C.uintptr_t, path *C.char, write C.bool) *C.char {
	if err := scopeOf(handle).call.Authorize(C.GoString(path), bool(write)); err != nil {
		return C.CString(automation.FailureOf(err))
	}
	return nil
}

//export swiptGraphicsScreenshot
func swiptGraphicsScreenshot(handle C.uintptr_t) C.swipt_graphics_screenshot {
	data, scale, err := scopeOf(handle).call.Screenshot()
	if err != nil {
		return C.swipt_graphics_screenshot{failure: C.CString(automation.FailureOf(err))}
	}
	return C.swipt_graphics_screenshot{image: C.CBytes(data), length: C.size_t(len(data)), scale: C.double(scale)}
}

//export swiptGraphicsWatchTimeline
func swiptGraphicsWatchTimeline(handle C.uintptr_t) C.uintptr_t {
	return C.uintptr_t(cgo.NewHandle(scopeOf(handle).call.WatchTimeline()))
}

//export swiptGraphicsStopTimeline
func swiptGraphicsStopTimeline(handle C.uintptr_t) *C.char {
	data, err := json.Marshal(cgo.Handle(handle).Value().(*automation.TimelineWatch).Stop())
	if err != nil {
		return C.CString("[]")
	}
	return C.CString(string(data))
}

//export swiptGraphicsPublish
func swiptGraphicsPublish(handle C.uintptr_t, value *C.char) {
	scopeOf(handle).publish(json.RawMessage(C.GoString(value)))
}

//export swiptGraphicsLogError
func swiptGraphicsLogError(message *C.char) {
	current.Load().options.Logger.Error(C.GoString(message))
}

//export swiptGraphicsRecordingFailed
func swiptGraphicsRecordingFailed(message *C.char) {
	options := current.Load().options
	text := C.GoString(message)
	options.Logger.Error("save the abandoned recording: ", text)
	if options.OnRecordingFailed != nil {
		options.OnRecordingFailed(text)
	}
}
