//go:build darwin && cgo

package phonemcp

import (
	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice/accessibility"
	"github.com/swipt-automation/swipt/internal/deviceserver"
	"github.com/swipt-automation/swipt/internal/jsc"
)

type recordedPush struct {
	Time         float64      `json:"time"`
	Kind         string       `json:"kind"`
	App          string       `json:"app,omitempty"`
	PID          uint64       `json:"pid,omitempty"`
	State        string       `json:"state,omitempty"`
	Notification string       `json:"notification,omitempty"`
	Nodes        []pushedNode `json:"nodes,omitempty"`
}

type pushedNode struct {
	PID        uint64 `json:"pid"`
	Label      string `json:"label,omitempty"`
	Identifier string `json:"identifier,omitempty"`
	Value      string `json:"value,omitempty"`
}

func (e *engine) record([]jsc.Value) (any, error) {
	recording, err := e.runner.phone.Record(e.run.ctx)
	if err != nil {
		return nil, err
	}
	e.sequence++
	e.recordings[e.sequence] = recording
	return e.sequence, nil
}

func (e *engine) stopRecording(arguments []jsc.Value) (any, error) {
	if len(arguments) == 0 {
		return nil, E.New("missing the recording")
	}
	id := int(arguments[0].Number())
	recording, found := e.recordings[id]
	if !found {
		return nil, E.New("the recording was already stopped")
	}
	delete(e.recordings, id)
	return common.Map(recording.Stop(), func(it deviceserver.Recorded) recordedPush {
		out := recordedPush{Time: float64(it.Time.UnixMicro()) / 1000}
		switch {
		case it.App != nil:
			out.Kind, out.App, out.PID, out.State = "app", it.App.BundleID, it.App.PID, it.App.State
		case it.AX.Notification != 0:
			out.Kind, out.PID, out.Notification = "notification", it.AX.PID, accessibility.NotificationName(it.AX.Notification)
		default:
			out.Kind = "tree"
			out.Nodes = common.Map(it.AX.Tree, func(node accessibility.PushedNode) pushedNode {
				return pushedNode{PID: node.PID, Label: node.Label, Identifier: node.Identifier, Value: node.Value}
			})
		}
		return out
	}), nil
}
