package main

import (
	"context"
	"net"
	"net/url"
	"os"
	"strings"

	"github.com/coder/websocket"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/proto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

const largestMessage = 128 << 20

type client struct {
	conn     *grpc.ClientConn
	system   proto.SystemServiceClient
	logs     proto.LogServiceClient
	swiplets proto.SwipletServiceClient
	repl     proto.REPLServiceClient
}

type bearerToken string

func (t bearerToken) GetRequestMetadata(context.Context, ...string) (map[string]string, error) {
	return map[string]string{"authorization": "Bearer " + string(t)}, nil
}

func (bearerToken) RequireTransportSecurity() bool {
	return false
}

func open() (*client, error) {
	if globalHost == "" {
		globalHost = os.Getenv("SWIPT_HOST")
	}
	if globalToken == "" {
		globalToken = os.Getenv("SWIPT_TOKEN")
	}
	if globalHost == "" {
		return nil, usageError{E.New(`give --host or set SWIPT_HOST; "swipt devices" lists the hosts on the local network`)}
	}
	host := globalHost
	if !strings.Contains(host, "://") {
		host = "http://" + host
	}
	parsed, err := url.Parse(host)
	if err != nil || parsed.Hostname() == "" {
		return nil, usageError{E.New("--host is not a URL: ", globalHost)}
	}
	options := []grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(largestMessage)),
	}
	if globalToken != "" {
		options = append(options, grpc.WithPerRPCCredentials(bearerToken(globalToken)))
	}
	address := parsed.Host
	switch parsed.Scheme {
	case "http":
		if parsed.Port() == "" {
			address = net.JoinHostPort(parsed.Hostname(), "80")
		}
	case "https":
		endpoint := "wss://" + parsed.Host + strings.TrimSuffix(parsed.EscapedPath(), "/") + "/"
		options = append(options, grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			conn, _, err := websocket.Dial(ctx, endpoint, nil)
			if err != nil {
				return nil, err
			}
			conn.SetReadLimit(-1)
			return websocket.NetConn(context.Background(), conn, websocket.MessageBinary), nil
		}))
	default:
		return nil, usageError{E.New("--host is an http or https URL: ", globalHost)}
	}
	conn, err := grpc.NewClient("passthrough:///"+address, options...)
	if err != nil {
		return nil, err
	}
	return &client{
		conn:     conn,
		system:   proto.NewSystemServiceClient(conn),
		logs:     proto.NewLogServiceClient(conn),
		swiplets: proto.NewSwipletServiceClient(conn),
		repl:     proto.NewREPLServiceClient(conn),
	}, nil
}

func (c *client) close() {
	_ = c.conn.Close()
}
