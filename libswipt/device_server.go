package libSwipt

import (
	"context"
	"net"
	"net/netip"
	"strconv"
	"sync"
	"sync/atomic"

	"github.com/swipt-automation/swipt/internal/coredevice"
	"github.com/swipt-automation/swipt/internal/coredevice/lockdown"
	"github.com/swipt-automation/swipt/internal/coredevice/vpnpeer"
	"github.com/swipt-automation/swipt/internal/deviceserver"
	"github.com/swipt-automation/swipt/internal/log"
	"github.com/swipt-automation/swipt/internal/phonemcp"
	"github.com/swipt-automation/swipt/internal/rfb"
)

const (
	DeviceServerStopped    int32 = 0
	DeviceServerConnecting int32 = 1
	DeviceServerPreparing  int32 = 2
	DeviceServerRunning    int32 = 3
	DeviceServerFailed     int32 = 4
)

const (
	DeviceErrorNone             int32 = 0
	DeviceErrorNoTunnel         int32 = 1
	DeviceErrorPairingRejected  int32 = 2
	DeviceErrorDeveloperModeOff int32 = 3
	DeviceErrorNoDiskImage      int32 = 4
	DeviceErrorDiskImage        int32 = 5
	DeviceErrorListen           int32 = 6
	DeviceErrorUnsupported      int32 = 7
	DeviceErrorScreenInUse      int32 = 8
	DeviceErrorPairing          int32 = 9
	DeviceErrorLoopbackAddress  int32 = 10
)

type DeviceServerOptions struct {
	PairingRecord      []byte
	RemotePairingPort  int32
	DiskImageDirectory string
	WorkflowDirectory  string
	AppBundleID        string
}

type DeviceServerSettings struct {
	AutoUnlockPasscode     string
	AutoUnlockPasscodeType int32
}

type MCPOptions struct {
	Port  int32
	Token string
}

const (
	WorkflowSourceFolder = phonemcp.SourceFolder
	WorkflowDataFolder   = phonemcp.DataFolder
	WorkflowEntryFile    = phonemcp.EntryFile
)

type DeviceServerHandler interface {
	OnStateChanged(state int32, errorCode int32, message string)
	OnDialog(dialogID int64, request string)
	OnDialogWithdrawn(dialogID int64)
	OnBackdrop(image []byte)
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

type DeviceServer struct {
	pairingPort atomic.Uint32
	logFactory  *log.Factory
	loopback    atomic.Pointer[LoopbackAddress]
	server      *deviceserver.Server
	runner      *phonemcp.Runner
	handler     DeviceServerHandler
	app         string

	dialogAccess sync.Mutex
	dialogs      map[int64]chan string
	lastDialog   int64
}

func NewDeviceServer(options *DeviceServerOptions, handler DeviceServerHandler) (*DeviceServer, error) {
	file, err := parsePairingFile(options.PairingRecord)
	if err != nil {
		return nil, err
	}
	name := "iPhone"
	if file.remote != nil && file.remote.DeviceName != "" {
		name = file.remote.DeviceName
	}
	logFactory := newLogFactory()
	connectLogger := logFactory.NewLogger("device")
	s := &DeviceServer{logFactory: logFactory, handler: handler, app: options.AppBundleID, dialogs: make(map[int64]chan string)}
	s.setPairingPort(options.RemotePairingPort)
	server, err := deviceserver.New(deviceserver.Options{
		Name: name,
		Connect: func(ctx context.Context) (*coredevice.Device, error) {
			port := uint16(s.pairingPort.Load())
			if file.lockdown != nil {
				port = lockdown.Port
			}
			peer, err := vpnpeer.Find(ctx, port)
			if err != nil {
				return nil, err
			}
			s.loopback.Store(newLoopbackAddress(peer))
			connectLogger.Info("device address: ", peer.Address, ", local network: ", peer.LocalNetwork)
			if file.lockdown != nil {
				return coredevice.ConnectLockdown(ctx, coredevice.LockdownOptions{
					Address: peer.Address,
					Record:  file.lockdown,
					Logger:  connectLogger,
				})
			}
			return coredevice.ConnectRemotePairing(ctx, coredevice.RemotePairingOptions{
				Address: netip.AddrPortFrom(peer.Address, port),
				Record:  file.remote,
				Logger:  connectLogger,
			})
		},
		Logger:             logFactory.Logger(),
		Observer:           &deviceObserver{handler: handler},
		DiskImageDirectory: options.DiskImageDirectory,
		BacklightState:     handler.BacklightState,
	})
	if err != nil {
		return nil, err
	}
	s.server = server
	s.runner = phonemcp.NewRunner(server.Phone(), phonemcp.RunnerOptions{
		Workflows: options.WorkflowDirectory, LogFactory: logFactory,
		Dialog: phonemcp.Dialog{App: s.app, InApp: true, Ask: s.ask, Backdrop: handler.OnBackdrop},
	})
	return s, nil
}

func (s *DeviceServer) Start() error {
	return s.server.Start()
}

func (s *DeviceServer) UpdateSettings(settings *DeviceServerSettings) error {
	return s.server.UpdateSettings(deviceserver.Settings{
		AutoUnlockPasscode:     settings.AutoUnlockPasscode,
		AutoUnlockPasscodeType: deviceserver.PasscodeType(settings.AutoUnlockPasscodeType),
	})
}

func (s *DeviceServer) SetMCP(local *MCPOptions, cloudflare *CloudflareOptions) error {
	tunnel, err := s.cloudflareMCP(cloudflare)
	if err != nil {
		return err
	}
	var localOptions *deviceserver.MCPOptions
	if local != nil {
		address := net.JoinHostPort("::", strconv.Itoa(int(local.Port)))
		localOptions = &deviceserver.MCPOptions{
			Listen: func() (net.Listener, error) {
				return net.Listen("tcp", address)
			},
			Server: phonemcp.New(s.runner, phonemcp.Options{Token: local.Token, Logger: s.logFactory.NewLogger("mcp")}),
		}
	}
	return s.server.SetMCP(localOptions, tunnel)
}

type Script struct {
	cancel  context.CancelFunc
	run     func() ([]phonemcp.OutputPart, error)
	answers chan string
}

type ScriptObserver interface {
	OnWaiting()
	OnRequest(request string)
}

func (s *DeviceServer) newScript(observer ScriptObserver, showsInApp bool, run func(ctx context.Context, dialog phonemcp.Dialog) ([]phonemcp.OutputPart, error)) *Script {
	ctx, cancel := context.WithCancel(context.Background())
	script := &Script{cancel: cancel, answers: make(chan string, 1)}
	dialog := phonemcp.Dialog{App: s.app, InApp: showsInApp, Backdrop: s.handler.OnBackdrop, Ask: func(ctx context.Context, request string) (string, error) {
		observer.OnRequest(request)
		select {
		case answer := <-script.answers:
			return answer, nil
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}}
	script.run = func() ([]phonemcp.OutputPart, error) { return run(ctx, dialog) }
	return script
}

func (s *DeviceServer) NewScript(code string, observer ScriptObserver, showsInApp bool) *Script {
	return s.newScript(observer, showsInApp, func(ctx context.Context, dialog phonemcp.Dialog) ([]phonemcp.OutputPart, error) {
		return s.runner.Run(ctx, code, dialog)
	})
}

func (s *DeviceServer) NewWorkflowRun(name string, observer ScriptObserver, showsInApp bool) *Script {
	return s.newScript(observer, showsInApp, func(ctx context.Context, dialog phonemcp.Dialog) ([]phonemcp.OutputPart, error) {
		return s.runner.RunWorkflow(ctx, name, observer.OnWaiting, dialog)
	})
}

func (s *DeviceServer) ask(ctx context.Context, request string) (string, error) {
	answers := make(chan string, 1)
	s.dialogAccess.Lock()
	s.lastDialog++
	id := s.lastDialog
	s.dialogs[id] = answers
	s.dialogAccess.Unlock()
	s.handler.OnDialog(id, request)
	select {
	case answer, answered := <-answers:
		if !answered {
			return "", phonemcp.ErrDismissed
		}
		return answer, nil
	case <-ctx.Done():
		if s.takeDialog(id) != nil {
			s.handler.OnDialogWithdrawn(id)
		}
		return "", ctx.Err()
	}
}

func (s *DeviceServer) takeDialog(id int64) chan string {
	s.dialogAccess.Lock()
	defer s.dialogAccess.Unlock()
	answers := s.dialogs[id]
	delete(s.dialogs, id)
	return answers
}

func (s *DeviceServer) AnswerDialog(dialogID int64, answer string) {
	if answers := s.takeDialog(dialogID); answers != nil {
		answers <- answer
	}
}

func (s *DeviceServer) DismissDialog(dialogID int64) {
	if answers := s.takeDialog(dialogID); answers != nil {
		close(answers)
	}
}

type ScriptOutput struct {
	parts []phonemcp.OutputPart
}

func (o *ScriptOutput) Count() int32 {
	return int32(len(o.parts))
}

func (o *ScriptOutput) Text(index int32) string {
	return o.parts[index].Text
}

func (o *ScriptOutput) Image(index int32) []byte {
	return o.parts[index].Image
}

func (s *Script) Run() (*ScriptOutput, error) {
	defer s.cancel()
	parts, err := s.run()
	if err != nil {
		return nil, err
	}
	return &ScriptOutput{parts: parts}, nil
}

func (s *Script) Answer(answer string) {
	select {
	case s.answers <- answer:
	default:
	}
}

func (s *Script) Cancel() {
	s.cancel()
}

func ScriptAPI() string {
	return phonemcp.Declarations
}

func (s *DeviceServer) ResetScript() error {
	return s.runner.Reset(context.Background())
}

func (s *DeviceServer) LoopbackAddress() *LoopbackAddress {
	return s.loopback.Load()
}

func (s *DeviceServer) SetRemotePairingPort(port int32) {
	if s.setPairingPort(port) {
		s.server.Retry()
	}
}

func (s *DeviceServer) setPairingPort(port int32) bool {
	if port == 0 {
		port = defaultRemotePairingPort
	}
	return s.pairingPort.Swap(uint32(port)) != uint32(port)
}

func (s *DeviceServer) Close() error {
	err := s.server.Close()
	s.runner.Close()
	return err
}

type deviceObserver struct {
	handler DeviceServerHandler
}

func (o *deviceObserver) StateChanged(state deviceserver.State, err error) {
	code, message := deviceError(err)
	o.handler.OnStateChanged(stateCode(state), code, message)
}

func (o *deviceObserver) DeviceConnected(info coredevice.DeviceInfo) {}

func (o *deviceObserver) ViewerConnected(session *rfb.ServerSession) {}

func (o *deviceObserver) ViewerDisconnected(session *rfb.ServerSession, err error) {}

func (o *deviceObserver) StreamingChanged(active bool) {}

func stateCode(state deviceserver.State) int32 {
	switch state {
	case deviceserver.StateConnecting:
		return DeviceServerConnecting
	case deviceserver.StatePreparing:
		return DeviceServerPreparing
	case deviceserver.StateRunning:
		return DeviceServerRunning
	case deviceserver.StateFailed:
		return DeviceServerFailed
	}
	return DeviceServerStopped
}

func deviceError(err error) (int32, string) {
	if err == nil {
		return DeviceErrorNone, ""
	}
	return int32(deviceserver.ProblemOf(err)), err.Error()
}
