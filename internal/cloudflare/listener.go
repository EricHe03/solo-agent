package cloudflare

import (
	"context"
	"net"
	"sync"
)

type pipeAddr struct{}

func (pipeAddr) Network() string { return "pipe" }

func (pipeAddr) String() string { return "pipe" }

type pipeListener struct {
	conns   chan net.Conn
	done    chan struct{}
	closed  sync.Once
	onClose func()
}

func newPipeListener(onClose func()) *pipeListener {
	return &pipeListener{conns: make(chan net.Conn), done: make(chan struct{}), onClose: onClose}
}

func (l *pipeListener) Accept() (net.Conn, error) {
	select {
	case conn := <-l.conns:
		return conn, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *pipeListener) Close() error {
	l.closed.Do(func() {
		close(l.done)
		if l.onClose != nil {
			l.onClose()
		}
	})
	return nil
}

func (l *pipeListener) Addr() net.Addr {
	return pipeAddr{}
}

func (l *pipeListener) dial(ctx context.Context) (net.Conn, error) {
	client, server := net.Pipe()
	select {
	case l.conns <- server:
		return client, nil
	case <-l.done:
		client.Close()
		server.Close()
		return nil, net.ErrClosed
	case <-ctx.Done():
		client.Close()
		server.Close()
		return nil, ctx.Err()
	}
}
