package libSwipt

import (
	"net"
	"strconv"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/api"
	"github.com/swipt-automation/swipt/internal/api/discovery"
)

const (
	APIMCPPath     = api.MCPPath
	APIServiceType = discovery.ServiceType
)

type APIOptions struct {
	Token                     string
	LocalNetwork              bool
	Port                      int32
	LocalNetworkAuthenticates bool
	Cloudflare                *CloudflareTunnel
	CloudflarePath            string
}

type apiState struct {
	server             *api.Server
	local              net.Listener
	localPort          int32
	localAuthenticates bool
	cloudflare         *CloudflareTunnel
	tunnel             net.Listener
	tunnelPath         string
}

func (p *Platform) serveAPI(state *apiState, listener net.Listener, prefix string, authenticates bool, name string) {
	if err := state.server.Serve(listener, prefix, authenticates); err != nil {
		err = E.Cause(err, "api: serve on ", name)
		p.logFactory.NewLogger("api").Error(err)
		p.handler.OnAPIFailed(err.Error())
	}
}

func (p *Platform) SetAPI(options *APIOptions) error {
	p.apiAccess.Lock()
	defer p.apiAccess.Unlock()
	state := p.api
	if options == nil || !options.LocalNetwork && options.Cloudflare == nil {
		p.api = nil
		if state != nil {
			_ = state.server.Close()
			closeListener(state.local)
			closeListener(state.tunnel)
		}
		return nil
	}
	if options.Token == "" {
		return E.New("api: missing token")
	}
	tunnelPath := strings.TrimSuffix(options.CloudflarePath, "/")
	if options.Cloudflare != nil && tunnelPath != "" && !strings.HasPrefix(tunnelPath, "/") {
		return E.New("cloudflare: invalid path ", options.CloudflarePath)
	}
	if state == nil {
		state = &apiState{server: api.New(api.Options{
			Device: p.device.connection, Swiplets: p.host, Dialog: p.dialog, Logs: p.logFactory, Logger: p.logFactory.NewLogger("api"),
			AppVersion: p.appVersion, AppBuild: p.appBuild,
		})}
		p.api = state
	}
	state.server.SetToken(options.Token)
	if state.cloudflare != options.Cloudflare || state.tunnelPath != tunnelPath {
		closeListener(state.tunnel)
		state.cloudflare, state.tunnel, state.tunnelPath = options.Cloudflare, nil, tunnelPath
		if options.Cloudflare != nil {
			listener, err := options.Cloudflare.tunnel.Listen()
			if err != nil {
				return err
			}
			state.tunnel = listener
			go p.serveAPI(state, listener, tunnelPath, true, "Cloudflare")
		}
	}
	if !options.LocalNetwork || state.localPort != options.Port || state.localAuthenticates != options.LocalNetworkAuthenticates {
		closeListener(state.local)
		state.local, state.localPort = nil, 0
	}
	if options.LocalNetwork && state.local == nil {
		listener, err := net.Listen("tcp", net.JoinHostPort("", strconv.Itoa(int(options.Port))))
		if err != nil {
			return E.Cause(err, "api: listen on port ", options.Port)
		}
		state.local, state.localPort, state.localAuthenticates = listener, options.Port, options.LocalNetworkAuthenticates
		go p.serveAPI(state, listener, "", options.LocalNetworkAuthenticates, "the local network")
	}
	return nil
}

func closeListener(listener net.Listener) {
	if listener != nil {
		_ = listener.Close()
	}
}
