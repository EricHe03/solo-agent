package deviceserver

import (
	"net"
	"net/http"
	"strconv"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	"github.com/swipt-automation/swipt/internal/rfb"
)

type ScreenSharingOptions struct {
	Listen string
	RFB    rfb.ServerOptions
}

type MCPOptions struct {
	Listen string
	Server interface {
		Serve(listener net.Listener) error
		Close() error
	}
}

type frontend struct {
	name    string
	address string
	server  interface {
		Serve(listener net.Listener) error
		Close() error
	}
	probe    func() error
	listener net.Listener
}

func (f *frontend) start(logger logger.ContextLogger) error {
	if f.listener != nil {
		_ = f.listener.Close()
	} else if f.probe != nil {
		if err := f.probe(); err != nil {
			return err
		}
	}
	listener, err := net.Listen("tcp", f.address)
	if err != nil {
		return &Error{Problem: ProblemListen, Err: E.Cause(err, "listen for ", f.name)}
	}
	f.listener = listener
	logger.Info(f.name, " listening on ", listener.Addr())
	go func() {
		err := f.server.Serve(listener)
		if err != nil && !E.IsMulti(err, rfb.ErrServerClosed, http.ErrServerClosed, net.ErrClosed) {
			logger.Error(E.Cause(err, "serve ", f.name))
		}
	}()
	return nil
}

func (s *Server) SetScreenSharing(options *ScreenSharingOptions) error {
	var viewers *rfb.Server
	var next *frontend
	if options != nil {
		host, _, err := net.SplitHostPort(options.Listen)
		if err != nil {
			return E.Cause(err, "deviceserver: parse listen address")
		}
		var ip net.IP
		if host != "" {
			ip = net.ParseIP(host)
			if ip == nil {
				return E.New("deviceserver: listen address ", strconv.Quote(host), " is not an IP address")
			}
		}
		rfbOptions := options.RFB
		rfbOptions.Name = s.options.Name
		rfbOptions.Media.ListenUDP = func(port uint16) (*net.UDPConn, error) {
			return net.ListenUDP("udp", &net.UDPAddr{IP: ip, Port: int(port)})
		}
		rfbOptions.Handler = (*viewerHandler)(s)
		rfbOptions.Logger = s.logger
		rfbOptions.SystemCommands = []rfb.SystemCommand{
			rfb.SystemCommandLaunchpad, rfb.SystemCommandShowDesktop,
			rfb.SystemCommandMissionControl, rfb.SystemCommandAppWindows,
		}
		viewers, err = rfb.NewServer(rfbOptions)
		if err != nil {
			return err
		}
		media := rfbOptions.Media
		next = &frontend{
			name: "screen sharing",
			address: options.Listen,
			server:  viewers,
			probe: func() error {
				for _, port := range []uint16{media.VideoPort, media.AudioPort} {
					conn, err := media.ListenUDP(port)
					if err != nil {
						return &Error{Problem: ProblemListen, Err: E.Cause(err, "listen on media port ", port)}
					}
					_ = conn.Close()
				}
				return nil
			},
		}
	}
	s.frontends.Lock()
	defer s.frontends.Unlock()
	err := s.replace(&s.sharing, next)
	s.access.Lock()
	s.rfb = nil
	if s.sharing != nil {
		s.rfb = viewers
	}
	s.access.Unlock()
	return err
}

func (s *Server) SetMCP(options *MCPOptions) error {
	var next *frontend
	if options != nil {
		next = &frontend{
			name:    "MCP",
			address: options.Listen,
			server:  options.Server,
		}
	}
	s.frontends.Lock()
	defer s.frontends.Unlock()
	return s.replace(&s.mcp, next)
}

func (s *Server) replace(slot **frontend, next *frontend) error {
	if s.retired {
		if next == nil {
			return nil
		}
		return E.New("deviceserver: stopped")
	}
	if *slot != nil {
		_ = (*slot).server.Close()
	}
	*slot = next
	if next == nil || !s.listening {
		return nil
	}
	err := next.start(s.logger)
	if err != nil {
		*slot = nil
	}
	return err
}

// When the screen locks while the app is suspended, iOS defuncts the app's sockets.
// A defunct listener stays open but never reports a connection or an error.
func (s *Server) listen() error {
	s.frontends.Lock()
	defer s.frontends.Unlock()
	s.listening = true
	for _, f := range []*frontend{s.sharing, s.mcp} {
		if f == nil {
			continue
		}
		if err := f.start(s.logger); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) closeFrontends() {
	s.frontends.Lock()
	defer s.frontends.Unlock()
	s.retired = true
	for _, f := range []*frontend{s.sharing, s.mcp} {
		if f != nil {
			_ = f.server.Close()
		}
	}
	s.sharing, s.mcp = nil, nil
	s.access.Lock()
	s.rfb = nil
	s.access.Unlock()
}

func (s *Server) viewers() *rfb.Server {
	s.access.Lock()
	defer s.access.Unlock()
	return s.rfb
}

func (s *Server) sessions() []*rfb.ServerSession {
	viewers := s.viewers()
	if viewers == nil {
		return nil
	}
	return viewers.Sessions()
}

func (s *Server) screenChanged() {
	if viewers := s.viewers(); viewers != nil {
		viewers.ScreenChanged()
	}
}
