package libSwipt

import (
	"context"
	"net/netip"
	"sync/atomic"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/automation"
	"github.com/swipt-automation/swipt/internal/coredevice"
	"github.com/swipt-automation/swipt/internal/coredevice/lockdown"
	"github.com/swipt-automation/swipt/internal/coredevice/vpnpeer"
	"github.com/swipt-automation/swipt/internal/device"
	"github.com/swipt-automation/swipt/internal/log"
	"github.com/swipt-automation/swipt/internal/rfb"
)

const (
	DeviceStopped    int32 = 0
	DeviceConnecting int32 = 1
	DevicePreparing  int32 = 2
	DeviceConnected  int32 = 3
	DeviceFailed     int32 = 4
)

const (
	DeviceErrorNone             int32 = 0
	DeviceErrorNoTunnel         int32 = 1
	DeviceErrorPairingRejected  int32 = 2
	DeviceErrorDeveloperModeOff int32 = 3
	DeviceErrorNoDiskImage      int32 = 4
	DeviceErrorDiskImage        int32 = 5
	DeviceErrorUnsupported      int32 = 7
	DeviceErrorScreenInUse      int32 = 8
	DeviceErrorPairing          int32 = 9
	DeviceErrorLoopbackAddress  int32 = 10
)

type DeviceOptions struct {
	RemotePairingPort  int32
	DiskImageDirectory string
}

type DeviceSettings struct {
	AutoUnlockPasscode     string
	AutoUnlockPasscodeType int32
}

type DeviceHandler interface {
	OnStateChanged(state int32, errorCode int32, message string)
	BacklightState() int32
}

const defaultRemotePairingPort = 49152

type LoopbackAddress struct {
	LocalNetwork bool
}

func newLoopbackAddress(peer vpnpeer.Peer) *LoopbackAddress {
	return &LoopbackAddress{LocalNetwork: peer.LocalNetwork}
}

type LoopbackProbe struct {
	ctx    context.Context
	cancel context.CancelFunc
	port   uint16
}

func NewLoopbackProbe(remotePairingPort int32) *LoopbackProbe {
	port := uint16(remotePairingPort)
	if port == 0 {
		port = defaultRemotePairingPort
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &LoopbackProbe{ctx: ctx, cancel: cancel, port: port}
}

func (p *LoopbackProbe) Run() (*LoopbackAddress, error) {
	defer p.cancel()
	peer, err := vpnpeer.Find(p.ctx, p.port)
	if p.ctx.Err() != nil {
		return nil, p.ctx.Err()
	}
	if err != nil {
		return nil, err
	}
	return newLoopbackAddress(peer), nil
}

func (p *LoopbackProbe) Cancel() {
	p.cancel()
}

type Device struct {
	logFactory  *log.Factory
	connection  *device.Connection
	services    *automation.Host
	pairingPort atomic.Uint32
	pairing     atomic.Pointer[pairingFile]
	loopback    atomic.Pointer[LoopbackAddress]
	unavailable atomic.Bool
}

func newDevice(options *DeviceOptions, handler DeviceHandler, logFactory *log.Factory) *Device {
	d := &Device{logFactory: logFactory}
	d.setPairingPort(options.RemotePairingPort)
	connectLogger := logFactory.NewLogger("device")
	d.connection = device.New(device.Options{
		Name: "iPhone",
		Connect: func(ctx context.Context) (*coredevice.Device, error) {
			file := d.pairing.Load()
			if file == nil {
				return nil, E.Cause1(device.ErrUnavailable, E.New("the device is not paired"))
			}
			port := uint16(d.pairingPort.Load())
			if file.lockdown != nil {
				port = lockdown.Port
			}
			peer, err := vpnpeer.Find(ctx, port)
			if err != nil {
				return nil, err
			}
			d.loopback.Store(newLoopbackAddress(peer))
			connectLogger.Info("device address: ", peer.Address, ", local network: ", peer.LocalNetwork)
			if file.lockdown != nil {
				return coredevice.ConnectLockdown(ctx, coredevice.LockdownOptions{Address: peer.Address, Record: file.lockdown, Logger: connectLogger})
			}
			return coredevice.ConnectRemotePairing(ctx, coredevice.RemotePairingOptions{
				Address: netip.AddrPortFrom(peer.Address, port), Record: file.remote, Logger: connectLogger,
			})
		},
		Logger:             logFactory.Logger(),
		Observer:           &deviceObserver{handler: handler},
		DiskImageDirectory: options.DiskImageDirectory,
		BacklightState:     handler.BacklightState,
	})
	return d
}

func (d *Device) SetPairingRecord(record []byte) error {
	if len(record) == 0 {
		d.pairing.Store(nil)
		d.connection.Retry()
		return nil
	}
	file, err := parsePairingFile(record)
	if err != nil {
		return err
	}
	d.pairing.Store(&file)
	if file.remote != nil && file.remote.DeviceName != "" {
		d.connection.SetName(file.remote.DeviceName)
	}
	d.connection.Retry()
	d.services.RetryServices()
	return nil
}

func (d *Device) SetUnavailable(message string) {
	if message != "" {
		d.unavailable.Store(true)
		d.connection.SetUnavailable(E.New(message))
		return
	}
	d.connection.SetUnavailable(nil)
	if d.unavailable.Swap(false) {
		d.services.RetryServices()
	}
}

func (d *Device) UpdateSettings(settings *DeviceSettings) error {
	return d.connection.UpdateSettings(device.Settings{
		AutoUnlockPasscode:     settings.AutoUnlockPasscode,
		AutoUnlockPasscodeType: device.PasscodeType(settings.AutoUnlockPasscodeType),
	})
}

func (d *Device) LoopbackAddress() *LoopbackAddress {
	return d.loopback.Load()
}

func (d *Device) SetRemotePairingPort(port int32) {
	if d.setPairingPort(port) {
		d.connection.Retry()
		d.services.RetryServices()
	}
}

func (d *Device) setPairingPort(port int32) bool {
	if port == 0 {
		port = defaultRemotePairingPort
	}
	return d.pairingPort.Swap(uint32(port)) != uint32(port)
}

type deviceObserver struct {
	handler DeviceHandler
}

func (o *deviceObserver) StateChanged(state device.State, err error) {
	code, message := deviceError(err)
	o.handler.OnStateChanged(stateCode(state), code, message)
}

func (o *deviceObserver) DeviceConnected(info coredevice.DeviceInfo) {}

func (o *deviceObserver) ViewerConnected(session *rfb.ServerSession) {}

func (o *deviceObserver) ViewerDisconnected(session *rfb.ServerSession, err error) {}

func (o *deviceObserver) StreamingChanged(active bool) {}

func stateCode(state device.State) int32 {
	switch state {
	case device.StateConnecting:
		return DeviceConnecting
	case device.StatePreparing:
		return DevicePreparing
	case device.StateRunning:
		return DeviceConnected
	case device.StateFailed:
		return DeviceFailed
	}
	return DeviceStopped
}

func deviceError(err error) (int32, string) {
	if err == nil {
		return DeviceErrorNone, ""
	}
	return int32(device.ProblemOf(err)), err.Error()
}
