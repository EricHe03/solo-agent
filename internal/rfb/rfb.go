package rfb

import (
	"fmt"
)

type Mode int

const (
	ModeObserve Mode = iota
	ModeControl
	ModeExclusiveControl
)

func (m Mode) String() string {
	switch m {
	case ModeObserve:
		return "observe"
	case ModeControl:
		return "control"
	case ModeExclusiveControl:
		return "exclusive"
	default:
		return fmt.Sprint("mode(", int(m), ")")
	}
}
