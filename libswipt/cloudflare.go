package libSwipt

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/cloudflare"
	"github.com/swipt-automation/swipt/internal/deviceserver"
	"github.com/swipt-automation/swipt/internal/phonemcp"
)

const (
	CloudflareModeQuickTunnel = int32(cloudflare.ModeQuickTunnel)
	CloudflareModeTunnel      = int32(cloudflare.ModeTunnel)
)

const zoneLookupTimeout = 30 * time.Second

type CloudflareTunnelOptions struct {
	Mode     int32
	Account  string
	Hostname string
	Tunnel   string
}

type CloudflareTunnelHandler interface {
	OnState(tunnel string, hostname string)
}

type CloudflareTunnel struct {
	tunnel *cloudflare.Tunnel
}

type CloudflareOptions struct {
	Tunnel *CloudflareTunnel
	Path   string
	Token  string
}

type CloudflareAccount struct {
	Credential string
	ZoneName   string
}

type CloudflareLogin struct {
	login *cloudflare.Login
}

func NewCloudflareLogin() *CloudflareLogin {
	return &CloudflareLogin{login: cloudflare.NewLogin()}
}

func (l *CloudflareLogin) LoginURL() string {
	return l.login.URL()
}

func (l *CloudflareLogin) Wait() (*CloudflareAccount, error) {
	account, err := l.login.Wait()
	if err != nil {
		return nil, err
	}
	credential, err := json.Marshal(account)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), zoneLookupTimeout)
	defer cancel()
	zone, _ := account.ZoneName(ctx)
	return &CloudflareAccount{Credential: string(credential), ZoneName: zone}, nil
}

func (l *CloudflareLogin) Cancel() {
	l.login.Cancel()
}

func NewCloudflareTunnel(options *CloudflareTunnelOptions, handler CloudflareTunnelHandler) (*CloudflareTunnel, error) {
	var account cloudflare.Account
	if options.Mode == CloudflareModeTunnel {
		var err error
		account, err = cloudflare.ParseAccount(options.Account)
		if err != nil {
			return nil, err
		}
		if options.Hostname == "" {
			return nil, E.New("cloudflare: missing hostname")
		}
	}
	return &CloudflareTunnel{tunnel: cloudflare.New(cloudflare.Options{
		Mode:     cloudflare.Mode(options.Mode),
		Account:  account,
		Hostname: options.Hostname,
		State:    options.Tunnel,
		OnState:  handler.OnState,
		Logger:   newLogFactory().NewLogger("cloudflare"),
	})}, nil
}

func (t *CloudflareTunnel) Close() error {
	return t.tunnel.Close()
}

func (s *DeviceServer) SetCloudflareMCP(options *CloudflareOptions) error {
	if options == nil {
		return s.server.SetTunnelMCP(nil)
	}
	if options.Tunnel == nil {
		return E.New("cloudflare: missing tunnel")
	}
	if options.Token == "" {
		return E.New("cloudflare: missing token")
	}
	if !strings.HasPrefix(options.Path, "/") {
		return E.New("cloudflare: invalid path ", options.Path)
	}
	return s.server.SetTunnelMCP(&deviceserver.MCPOptions{
		Listen: options.Tunnel.tunnel.Listen,
		Server: phonemcp.New(s.runner, phonemcp.Options{Token: options.Token, Path: options.Path, Logger: s.logFactory.NewLogger("mcp")}),
	})
}
