package rfb

import (
	"fmt"
)

type GesturePhase uint32

const (
	PhaseNone      GesturePhase = 0
	PhaseBegan     GesturePhase = 1
	PhaseChanged   GesturePhase = 2
	PhaseEnded     GesturePhase = 4
	PhaseCancelled GesturePhase = 8
)

type SwipeDirection int

const (
	SwipeBack SwipeDirection = iota
	SwipeForward
	SwipeUp
	SwipeDown
)

type SystemCommand uint32

const (
	SystemCommandLaunchpad      SystemCommand = 0x1008fd00
	SystemCommandShowDesktop    SystemCommand = 0x1008fd01
	SystemCommandMissionControl SystemCommand = 0x1008fd02
	SystemCommandAppWindows     SystemCommand = 0x1008fd03
)

func (s SystemCommand) String() string {
	switch s {
	case SystemCommandLaunchpad:
		return "launchpad"
	case SystemCommandShowDesktop:
		return "show-desktop"
	case SystemCommandMissionControl:
		return "mission-control"
	case SystemCommandAppWindows:
		return "app-windows"
	default:
		return fmt.Sprintf("system-command(%#x)", uint32(s))
	}
}

const (
	eventGestureStart        = 1
	eventGestureEnd          = 2
	eventGestureMagnify      = 3
	eventGestureSmartMagnify = 4
	eventGestureRotate       = 5
	eventGestureSwipe        = 6
	eventGestureLookup       = 7
	eventGestureScroll       = 8
	eventScrollWheel         = 11
)
