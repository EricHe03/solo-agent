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
	record(at, name, detail, duration)
}

func record(at time.Time, name, detail string, duration time.Duration) {
	if fn := tracer.Load(); fn != nil {
		(*fn)(Trace{At: at, Name: name, Detail: detail, Duration: duration})
	}
}
