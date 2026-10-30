package device

import (
	"net"
	"strconv"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	"github.com/swipt-automation/swipt/internal/rfb"
)

type ScreenSharingOptions struct {
	Listen string
	RFB    rfb.ServerOptions
}

type frontend struct {
	address  string
	server   *rfb.Server
	probe    func() error
	listener net.Listener
}

func (f *frontend) start(logger logger.ContextLogger) error {
	if err := f.probe(); err != nil {
		return err
	}
	listener, err := net.Listen("tcp", f.address)
	if err != nil {
		return &Error{Problem: ProblemListen, Err: E.Cause(err, "listen for screen sharing")}
	}
	f.listener = listener
	logger.Info("screen sharing listening on ", listener.Addr())
	go func() {
		err := f.server.Serve(listener)
		if err != nil && !E.IsMulti(err, rfb.ErrServerClosed, net.ErrClosed) {
			logger.Error(E.Cause(err, "serve screen sharing"))
		}
	}()
	return nil
}

func (s *Connection) SetScreenSharing(options *ScreenSharingOptions) error {
	var viewers *rfb.Server
	var next *frontend
	if options != nil {
		host, _, err := net.SplitHostPort(options.Listen)
		if err != nil {
			return E.Cause(err, "device: parse listen address")
		}
		var ip net.IP
		if host != "" {
			ip = net.ParseIP(host)
			if ip == nil {
				return E.New("device: listen address ", strconv.Quote(host), " is not an IP address")
			}
		}
		rfbOptions := options.RFB
		rfbOptions.Name = *s.name.Load()
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
	if s.retired {
		if next == nil {
			return nil
		}
		return E.New("device: stopped")
	}
	if s.sharing != nil {
		_ = s.sharing.server.Close()
	}
	s.sharing = next
	var err error
	if next != nil && s.listening {
		if err = next.start(s.logger); err != nil {
			s.sharing = nil
		}
	}
	s.access.Lock()
	s.rfb = nil
	if s.sharing != nil {
		s.rfb = viewers
	}
	s.access.Unlock()
	return err
}

func (s *Connection) listen() error {
	s.frontends.Lock()
	defer s.frontends.Unlock()
	s.listening = true
	if s.sharing == nil || s.sharing.listener != nil {
		return nil
	}
	return s.sharing.start(s.logger)
}

func (s *Connection) closeFrontends() {
	s.frontends.Lock()
	defer s.frontends.Unlock()
	s.retired = true
	if s.sharing != nil {
		_ = s.sharing.server.Close()
	}
	s.sharing = nil
	s.access.Lock()
	s.rfb = nil
	s.access.Unlock()
}

func (s *Connection) viewers() *rfb.Server {
	s.access.Lock()
	defer s.access.Unlock()
	return s.rfb
}

func (s *Connection) sessions() []*rfb.ServerSession {
	viewers := s.viewers()
	if viewers == nil {
		return nil
	}
	return viewers.Sessions()
}

func (s *Connection) screenChanged() {
	if viewers := s.viewers(); viewers != nil {
		s.access.Lock()
		screen := s.screen
		s.access.Unlock()
		viewers.ScreenChanged(screen)
	}
}
