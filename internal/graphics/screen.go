//go:build darwin && cgo

package graphics

/*
#include <stdlib.h>
#include "graphics.h"
*/
import "C"

import (
	"context"
	"runtime/cgo"
	"time"
	"unsafe"

	"github.com/swipt-automation/swipt/internal/automation"
	"github.com/swipt-automation/swipt/internal/device"
)

const screenOpenLimit = 20 * time.Second

//export swiptGraphicsOpenScreen
func swiptGraphicsOpenScreen() C.swipt_graphics_screen {
	ctx, cancel := context.WithTimeout(context.Background(), screenOpenLimit)
	defer cancel()
	feed, err := current.Load().options.Connection.OpenScreen(ctx, deliverScreen, endScreen)
	if err != nil {
		return C.swipt_graphics_screen{failure: C.CString(automation.FailureOf(err))}
	}
	info := feed.Info()
	return C.swipt_graphics_screen{feed: C.uintptr_t(cgo.NewHandle(feed)), width: C.int64_t(info.Width), height: C.int64_t(info.Height), scale: C.double(info.Scale)}
}

//export swiptGraphicsRequestKeyFrame
func swiptGraphicsRequestKeyFrame(handle C.uintptr_t) {
	cgo.Handle(handle).Value().(*device.ScreenFeed).RequestKeyFrame()
}

//export swiptGraphicsCloseScreen
func swiptGraphicsCloseScreen(handle C.uintptr_t) {
	cgo.Handle(handle).Value().(*device.ScreenFeed).Close()
}

func deliverScreen(batch []byte) {
	if len(batch) > 0 {
		C.swipt_graphics_screen_packets(unsafe.Pointer(&batch[0]), C.size_t(len(batch)))
	}
}

func endScreen(err error) {
	failure := C.CString(automation.FailureOf(err))
	defer C.free(unsafe.Pointer(failure))
	C.swipt_graphics_screen_ended(failure)
}
