//go:build darwin && !ios

package main

import (
	"context"
	"errors"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"strconv"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice"
	"github.com/swipt-automation/swipt/internal/coredevice/imagemounter"
	"github.com/swipt-automation/swipt/internal/deviceserver"
	"github.com/swipt-automation/swipt/internal/phonemcp"
	"github.com/swipt-automation/swipt/internal/rfb"
	"github.com/swipt-automation/swipt/internal/rfb/media"

	"github.com/spf13/cobra"
)

var (
	serveDevice             string
	serveVNCPort            uint16
	serveVNCUsername        string
	serveVNCPassword        string
	serveMCPPort            uint16
	serveMCPToken           string
	serveWorkflows          string
	serveUnlockPasscode     string
	serveUnlockPasscodeType string
)

var commandServe = &cobra.Command{
	Use:   "serve",
	Short: "Serve the device to Screen Sharing viewers and MCP clients",
	Args:  cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		err := serve(cmd.Context())
		if err != nil {
			fatal(err)
		}
	},
}

func init() {
	flags := commandServe.Flags()
	flags.StringVarP(&serveDevice, "device", "d", "", "UDID of the device to serve, needed when more than one is connected")
	flags.Uint16Var(&serveVNCPort, "vnc-port", 0, "port Screen Sharing viewers connect to, such as 5910; video and audio use the next two ports; without it, Screen Sharing is off")
	flags.StringVar(&serveVNCUsername, "vnc-username", "", "user name Screen Sharing viewers sign in with")
	flags.StringVar(&serveVNCPassword, "vnc-password", "", "password Screen Sharing viewers sign in with; without a user name and password, viewers connect without signing in")
	flags.Uint16Var(&serveMCPPort, "mcp-port", 0, "port MCP clients connect to at http://HOST:PORT/mcp, such as 5920; without it, MCP is off")
	flags.StringVar(&serveMCPToken, "mcp-token", "", "token MCP clients send as the user name of the URL, as in http://TOKEN@HOST:PORT/mcp; without it, clients connect without one")
	flags.StringVar(&serveWorkflows, "workflows", "", "directory that holds the workflows of MCP scripts; without it, scripts have no workflows")
	flags.StringVar(&serveUnlockPasscode, "unlock-passcode", "", "the device's passcode, to unlock it automatically")
	flags.StringVar(&serveUnlockPasscodeType, "unlock-passcode-type", "pin", "type of the device's passcode: pin (4 or 6 digits), numeric or alphanumeric")
	mainCommand.AddCommand(commandServe)
}

func serve(ctx context.Context) error {
	if serveVNCPort == 0 && serveMCPPort == 0 {
		return E.New("set --vnc-port, --mcp-port or both")
	}
	if serveVNCPort > 65533 {
		return E.New("--vnc-port must be at most 65533, since video and audio use the next two ports")
	}
	if (serveVNCUsername == "") != (serveVNCPassword == "") {
		return E.New("--vnc-username and --vnc-password must be set together")
	}
	var passcodeType deviceserver.PasscodeType
	switch serveUnlockPasscodeType {
	case "pin":
		passcodeType = deviceserver.PasscodePIN
	case "numeric":
		passcodeType = deviceserver.PasscodeNumeric
	case "alphanumeric":
		passcodeType = deviceserver.PasscodeAlphanumeric
	default:
		return E.New("--unlock-passcode-type must be pin, numeric or alphanumeric")
	}
	device, err := selectDevice(ctx, serveDevice)
	if err != nil {
		return err
	}
	name := device.Name
	if name == "" {
		name = "iPhone"
	}
	deviceLogger := logFactory.NewLogger("device")
	observer := &serveObserver{failed: make(chan error, 1)}
	server, err := deviceserver.New(deviceserver.Options{
		Name: name,
		Connect: func(ctx context.Context) (*coredevice.Device, error) {
			return coredevice.ConnectUSBMux(ctx, device.UDID, deviceLogger)
		},
		Logger:             logger,
		Observer:           observer,
		DiskImageDirectory: imagemounter.XcodeDirectory,
	})
	if err != nil {
		return err
	}
	err = server.UpdateSettings(deviceserver.Settings{
		AutoUnlockPasscode:     serveUnlockPasscode,
		AutoUnlockPasscodeType: passcodeType,
	})
	if err != nil {
		return err
	}
	if serveVNCPort != 0 {
		err = server.SetScreenSharing(&deviceserver.ScreenSharingOptions{
			Listen: net.JoinHostPort("::", strconv.Itoa(int(serveVNCPort))),
			RFB: rfb.ServerOptions{
				Username:         serveVNCUsername,
				Password:         serveVNCPassword,
				NoAuthentication: serveVNCPassword == "",
				Media: media.ServerStreamConfig{
					AllowLoopbackTarget: true,
					VideoPort:           serveVNCPort + 1,
					AudioPort:           serveVNCPort + 2,
				},
			},
		})
		if err != nil {
			return err
		}
	}
	if serveMCPPort != 0 {
		err = server.SetMCP(&deviceserver.MCPOptions{
			Listen: func() (net.Listener, error) {
				return net.Listen("tcp", net.JoinHostPort("::", strconv.Itoa(int(serveMCPPort))))
			},
			Server: phonemcp.New(phonemcp.NewRunner(server.Phone(), phonemcp.RunnerOptions{Workflows: serveWorkflows, LogFactory: logFactory}), phonemcp.Options{Token: serveMCPToken, Logger: logFactory.NewLogger("mcp")}),
		})
		if err != nil {
			return err
		}
	}
	logger.Info("serving the device: ", name, " (", device.UDID, ")")
	err = server.Start()
	if err != nil {
		return err
	}
	var failure error
	select {
	case <-ctx.Done():
	case failure = <-observer.failed:
	}
	server.Close()
	if deviceserver.ProblemOf(failure) == deviceserver.ProblemNoDiskImage {
		_, err = os.Stat(filepath.Join(imagemounter.XcodeDirectory, "BuildManifest.plist"))
		if errors.Is(err, fs.ErrNotExist) {
			return E.New("the device has no Developer Disk Image mounted, and this Mac has none in ", imagemounter.XcodeDirectory, "; install Xcode and open it once")
		}
	}
	return failure
}

type serveObserver struct {
	failed chan error
}

func (o *serveObserver) StateChanged(state deviceserver.State, err error) {
	if state == deviceserver.StateFailed {
		select {
		case o.failed <- err:
		default:
		}
	}
}

func (o *serveObserver) DeviceConnected(info coredevice.DeviceInfo) {}

func (o *serveObserver) ViewerConnected(session *rfb.ServerSession) {}

func (o *serveObserver) ViewerDisconnected(session *rfb.ServerSession, err error) {}

func (o *serveObserver) StreamingChanged(active bool) {}
