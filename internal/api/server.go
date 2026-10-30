package api

import (
	"context"
	"crypto/subtle"
	"errors"
	"net"
	"net/http"
	"runtime/debug"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/nekohasekai/go-sdk/mcp"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	swiptv1 "github.com/swipt-automation/swipt/internal/api/gen/swipt/v1"
	"github.com/swipt-automation/swipt/internal/automation"
	"github.com/swipt-automation/swipt/internal/device"
	"github.com/swipt-automation/swipt/internal/log"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
)

const (
	MCPPath = "/mcp"

	chunkSize         = 256 << 10
	keepaliveInterval = 30 * time.Second
	headerTimeout     = 10 * time.Second
)

var (
	errNoToken         = status.Error(codes.Unauthenticated, "the API requires a token")
	errUnauthenticated = status.Error(codes.Unauthenticated, "the token is wrong")
	errTokenReset      = status.Error(codes.Unauthenticated, "the token was reset")
	errStopped         = status.Error(codes.Unavailable, "the API stopped")
)

type anonymousKey struct{}

type anonymousAddr struct {
	net.Addr
}

type anonymousConn struct {
	net.Conn
}

func (c anonymousConn) RemoteAddr() net.Addr {
	return anonymousAddr{c.Conn.RemoteAddr()}
}

type Options struct {
	Device   *device.Connection
	Swiplets *automation.Host
	Dialog   automation.Dialog
	Logs     *log.Factory
	Logger   logger.ContextLogger
}

type Server struct {
	options  Options
	ctx      context.Context
	cancel   context.CancelFunc
	grpc     *grpc.Server
	upgraded *connListener
	servers  []*http.Server
	mcp      *mcp.Server
	mcpHTTP  http.Handler

	access   sync.Mutex
	token    string
	session  *automation.REPL
	sessions map[*mcp.ServerSession]*automation.REPL
	requests map[uint64]context.CancelCauseFunc
	sequence uint64
	closed   bool
}

func New(options Options) *Server {
	if options.Logger == nil {
		options.Logger = logger.NOP()
	}
	s := &Server{
		options:  options,
		upgraded: newConnListener(),
		sessions: make(map[*mcp.ServerSession]*automation.REPL),
		requests: make(map[uint64]context.CancelCauseFunc),
	}
	s.ctx, s.cancel = context.WithCancel(context.Background())
	s.grpc = grpc.NewServer(
		grpc.UnaryInterceptor(func(ctx context.Context, request any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
			ctx, release, err := s.authorize(ctx)
			if err != nil {
				return nil, err
			}
			defer release()
			return handler(ctx, request)
		}),
		grpc.StreamInterceptor(func(server any, stream grpc.ServerStream, _ *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
			ctx, release, err := s.authorize(stream.Context())
			if err != nil {
				return err
			}
			defer release()
			return handler(server, &authorizedStream{ServerStream: stream, ctx: ctx})
		}),
		grpc.KeepaliveParams(keepalive.ServerParameters{Time: keepaliveInterval}),
	)
	swiptv1.RegisterSystemServiceServer(s.grpc, &systemService{Server: s})
	swiptv1.RegisterLogServiceServer(s.grpc, &logService{Server: s})
	swiptv1.RegisterSwipletServiceServer(s.grpc, &swipletService{Server: s})
	swiptv1.RegisterREPLServiceServer(s.grpc, &replService{Server: s})
	go func() {
		_ = s.grpc.Serve(s.upgraded)
	}()
	s.mcp, s.mcpHTTP = s.newMCP()
	return s
}

func (s *Server) handler(prefix string, authenticates bool) http.Handler {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/" && strings.EqualFold(r.Header.Get("Upgrade"), "websocket"):
			s.serveWebSocket(w, r, authenticates)
		case r.ProtoMajor == 2 && strings.HasPrefix(r.Header.Get("Content-Type"), "application/grpc"):
			if !authenticates {
				r = r.WithContext(context.WithValue(r.Context(), anonymousKey{}, true))
			}
			s.grpc.ServeHTTP(w, r)
		case r.URL.Path == MCPPath:
			s.serveMCP(w, r, authenticates)
		default:
			http.NotFound(w, r)
		}
	})
	prefix = strings.TrimSuffix(prefix, "/")
	if prefix == "" {
		return handler
	}
	return http.StripPrefix(prefix, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "":
			r.URL.Path = "/"
		case r.URL.Path[0] != '/':
			http.NotFound(w, r)
			return
		}
		handler(w, r)
	}))
}

func (s *Server) serveWebSocket(w http.ResponseWriter, r *http.Request, authenticates bool) {
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		s.options.Logger.Debug("accept a websocket: ", err)
		return
	}
	conn.SetReadLimit(-1)
	upgraded := websocket.NetConn(s.ctx, conn, websocket.MessageBinary)
	if !authenticates {
		upgraded = anonymousConn{upgraded}
	}
	if !s.upgraded.push(upgraded) {
		conn.CloseNow()
	}
}

func (s *Server) Serve(listener net.Listener, prefix string, authenticates bool) error {
	var protocols http.Protocols
	protocols.SetHTTP1(true)
	protocols.SetUnencryptedHTTP2(true)
	server := &http.Server{
		Handler:           http.NewCrossOriginProtection().Handler(s.handler(prefix, authenticates)),
		Protocols:         &protocols,
		ReadHeaderTimeout: headerTimeout,
	}
	s.access.Lock()
	if s.closed {
		s.access.Unlock()
		return listener.Close()
	}
	s.servers = append(s.servers, server)
	s.access.Unlock()
	tracked := &trackedListener{Listener: listener, conns: make(map[*trackedConn]struct{})}
	err := server.Serve(tracked)
	tracked.closeConns()
	s.access.Lock()
	s.servers = slices.DeleteFunc(s.servers, func(it *http.Server) bool { return it == server })
	s.access.Unlock()
	if errors.Is(err, net.ErrClosed) || errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func (s *Server) SetToken(token string) {
	s.access.Lock()
	if token == s.token {
		s.access.Unlock()
		return
	}
	s.token = token
	ended := s.takeSessions()
	cancels := s.requests
	s.requests = make(map[uint64]context.CancelCauseFunc)
	s.access.Unlock()
	for _, cancel := range cancels {
		cancel(errTokenReset)
	}
	ended()
}

func (s *Server) authorized(token string) bool {
	s.access.Lock()
	current := s.token
	s.access.Unlock()
	return current != "" && subtle.ConstantTimeCompare([]byte(token), []byte(current)) == 1
}

func anonymous(ctx context.Context) bool {
	if allowed, _ := ctx.Value(anonymousKey{}).(bool); allowed {
		return true
	}
	if connection, loaded := peer.FromContext(ctx); loaded {
		_, allowed := connection.Addr.(anonymousAddr)
		return allowed
	}
	return false
}

func (s *Server) authorize(ctx context.Context) (context.Context, func(), error) {
	if !anonymous(ctx) {
		md, _ := metadata.FromIncomingContext(ctx)
		values := md.Get("authorization")
		if len(values) == 0 {
			return nil, nil, errNoToken
		}
		token, isBearer := strings.CutPrefix(values[0], "Bearer ")
		if !isBearer || !s.authorized(token) {
			return nil, nil, errUnauthenticated
		}
	}
	ctx, cancel := context.WithCancelCause(ctx)
	s.access.Lock()
	if s.closed {
		s.access.Unlock()
		cancel(nil)
		return nil, nil, errStopped
	}
	s.sequence++
	id := s.sequence
	s.requests[id] = cancel
	s.access.Unlock()
	return ctx, func() {
		s.access.Lock()
		delete(s.requests, id)
		s.access.Unlock()
		cancel(nil)
	}, nil
}

type authorizedStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (s *authorizedStream) Context() context.Context {
	return s.ctx
}

func (s *Server) cliSession() (*automation.REPL, error) {
	s.access.Lock()
	defer s.access.Unlock()
	if s.closed {
		return nil, errStopped
	}
	if s.session == nil {
		s.session = s.options.Swiplets.NewREPL(s.options.Dialog)
	}
	return s.session, nil
}

func (s *Server) takeSessions() func() {
	cli := s.session
	s.session = nil
	return func() {
		if cli != nil {
			cli.Close()
		}
		for session := range s.mcp.Sessions() {
			_ = session.Close()
		}
	}
}

func (s *Server) Close() error {
	s.access.Lock()
	if s.closed {
		s.access.Unlock()
		return nil
	}
	s.closed = true
	ended := s.takeSessions()
	servers := s.servers
	s.access.Unlock()
	var err error
	for _, server := range servers {
		err = E.Errors(err, server.Close())
	}
	s.grpc.Stop()
	_ = s.upgraded.Close()
	s.cancel()
	ended()
	return err
}

func serverVersion() string {
	info, loaded := debug.ReadBuildInfo()
	if !loaded || info.Main.Version == "" {
		return "(devel)"
	}
	return info.Main.Version
}
