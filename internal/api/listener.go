package api

import (
	"net"
	"sync"
)

type connListener struct {
	conns chan net.Conn
	done  chan struct{}
	once  sync.Once
}

func newConnListener() *connListener {
	return &connListener{conns: make(chan net.Conn), done: make(chan struct{})}
}

func (l *connListener) push(conn net.Conn) bool {
	select {
	case l.conns <- conn:
		return true
	case <-l.done:
		return false
	}
}

func (l *connListener) Accept() (net.Conn, error) {
	select {
	case conn := <-l.conns:
		return conn, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *connListener) Close() error {
	l.once.Do(func() { close(l.done) })
	return nil
}

func (l *connListener) Addr() net.Addr {
	return &net.TCPAddr{}
}

type trackedListener struct {
	net.Listener
	access sync.Mutex
	conns  map[*trackedConn]struct{}
	closed bool
}

func (l *trackedListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	tracked := &trackedConn{Conn: conn, listener: l}
	l.access.Lock()
	defer l.access.Unlock()
	if l.closed {
		_ = conn.Close()
		return nil, net.ErrClosed
	}
	l.conns[tracked] = struct{}{}
	return tracked, nil
}

func (l *trackedListener) closeConns() {
	l.access.Lock()
	l.closed = true
	conns := l.conns
	l.conns = nil
	l.access.Unlock()
	for conn := range conns {
		_ = conn.Conn.Close()
	}
}

type trackedConn struct {
	net.Conn
	listener *trackedListener
	once     sync.Once
}

func (c *trackedConn) Close() error {
	c.once.Do(func() {
		c.listener.access.Lock()
		delete(c.listener.conns, c)
		c.listener.access.Unlock()
	})
	return c.Conn.Close()
}
