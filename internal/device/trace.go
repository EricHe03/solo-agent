package device

import (
	"sync/atomic"
	"time"
)

type Trace struct {
	At       time.Time
	Name     string
	Detail   string
	Duration time.Duration
}

var tracer atomic.Pointer[func(Trace)]

func (p *Phone) Trace(fn func(Trace)) {
	tracer.Store(&fn)
}

func (s *Connection) trace(at time.Time, name, detail string, duration time.Duration) {
	s.logger.Debug(name, ": ", detail, " (", duration, ")")
	if fn := tracer.Load(); fn != nil {
		(*fn)(Trace{At: at, Name: name, Detail: detail, Duration: duration})
	}
}
