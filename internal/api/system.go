package api

import (
	"context"

	swiptv1 "github.com/swipt-automation/swipt/internal/api/gen/swipt/v1"
	"github.com/swipt-automation/swipt/internal/device"
)

type systemService struct {
	swiptv1.UnimplementedSystemServiceServer
	*Server
}

func deviceConnection(state device.State, err error) *swiptv1.DeviceConnection {
	out := &swiptv1.DeviceConnection{}
	switch state {
	case device.StateStopped:
		out.State = swiptv1.DeviceConnectionState_DEVICE_CONNECTION_STATE_STOPPED
	case device.StateConnecting:
		out.State = swiptv1.DeviceConnectionState_DEVICE_CONNECTION_STATE_CONNECTING
	case device.StatePreparing:
		out.State = swiptv1.DeviceConnectionState_DEVICE_CONNECTION_STATE_PREPARING
	case device.StateRunning:
		out.State = swiptv1.DeviceConnectionState_DEVICE_CONNECTION_STATE_RUNNING
	case device.StateFailed:
		out.State = swiptv1.DeviceConnectionState_DEVICE_CONNECTION_STATE_FAILED
	}
	if err == nil {
		return out
	}
	out.Message = err.Error()
	switch device.ProblemOf(err) {
	case device.ProblemNoTunnel:
		out.Problem = swiptv1.DeviceConnectionProblem_DEVICE_CONNECTION_PROBLEM_UNREACHABLE
	case device.ProblemPairingRejected:
		out.Problem = swiptv1.DeviceConnectionProblem_DEVICE_CONNECTION_PROBLEM_PAIRING_REJECTED
	case device.ProblemDeveloperModeOff:
		out.Problem = swiptv1.DeviceConnectionProblem_DEVICE_CONNECTION_PROBLEM_DEVELOPER_MODE_OFF
	case device.ProblemNoDiskImage:
		out.Problem = swiptv1.DeviceConnectionProblem_DEVICE_CONNECTION_PROBLEM_DISK_IMAGE_MISSING
	case device.ProblemDiskImage:
		out.Problem = swiptv1.DeviceConnectionProblem_DEVICE_CONNECTION_PROBLEM_DISK_IMAGE_MOUNT_FAILED
	case device.ProblemUnsupported:
		out.Problem = swiptv1.DeviceConnectionProblem_DEVICE_CONNECTION_PROBLEM_DEVICE_UNSUPPORTED
	case device.ProblemScreenInUse:
		out.Problem = swiptv1.DeviceConnectionProblem_DEVICE_CONNECTION_PROBLEM_SCREEN_IN_USE
	case device.ProblemLoopbackAddress:
		out.Problem = swiptv1.DeviceConnectionProblem_DEVICE_CONNECTION_PROBLEM_VPN_PEER_ADDRESS_MISSING
	default:
		out.Problem = swiptv1.DeviceConnectionProblem_DEVICE_CONNECTION_PROBLEM_OTHER
	}
	return out
}

func (s *systemService) GetInfo(context.Context, *swiptv1.GetInfoRequest) (*swiptv1.GetInfoResponse, error) {
	return &swiptv1.GetInfoResponse{
		ServerVersion:    serverVersion(),
		DeviceName:       s.options.Device.Name(),
		Udid:             s.options.Device.DeviceInfo().UDID,
		DeviceConnection: deviceConnection(s.options.Device.State()),
	}, nil
}
