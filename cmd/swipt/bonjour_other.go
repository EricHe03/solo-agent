//go:build !darwin || ios || !cgo

package main

import (
	"context"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

func browseBonjour(context.Context, time.Duration) ([]bonjourService, error) {
	return nil, E.New("swipt devices needs a macOS build of swipt with cgo")
}
