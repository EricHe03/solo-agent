package log

import (
	"context"
	"sync"
	"time"

	F "github.com/sagernet/sing/common/format"
	"github.com/sagernet/sing/common/logger"
)

type (
	Logger        = logger.Logger
	ContextLogger = logger.ContextLogger
)

type PlatformWriter interface {
	WriteMessage(level Level, message string)
}

type Entry struct {
	Time    time.Time
	Level   Level
	Tag     string
	Message string
}

const entryCapacity = 4096

type Options struct {
	Level          Level
	PlatformWriter PlatformWriter
}

type Factory struct {
	level          Level
	platformWriter PlatformWriter

	access      sync.Mutex
	entries     []Entry
	start       int
	subscribers map[int]func(Entry)
	next        int
}

func NewFactory(options Options) *Factory {
	return &Factory{
		level:          options.Level,
		platformWriter: options.PlatformWriter,
		subscribers:    make(map[int]func(Entry)),
	}
}

func (f *Factory) Subscribe(receive func(Entry)) (backlog []Entry, cancel func()) {
	f.access.Lock()
	defer f.access.Unlock()
	backlog = append(append(backlog, f.entries[f.start:]...), f.entries[:f.start]...)
	f.next++
	id := f.next
	f.subscribers[id] = receive
	return backlog, func() {
		f.access.Lock()
		delete(f.subscribers, id)
		f.access.Unlock()
	}
}

func (f *Factory) Logger() ContextLogger {
	return f.NewLogger("")
}

func (f *Factory) NewLogger(tag string) ContextLogger {
	return &factoryLogger{factory: f, tag: tag}
}

func (f *Factory) output(level Level, tag string, message string) {
	if level <= LevelDebug {
		entry := Entry{Time: time.Now(), Level: level, Tag: tag, Message: message}
		f.access.Lock()
		if len(f.entries) < entryCapacity {
			f.entries = append(f.entries, entry)
		} else {
			f.entries[f.start] = entry
			f.start = (f.start + 1) % entryCapacity
		}
		for _, receive := range f.subscribers {
			receive(entry)
		}
		f.access.Unlock()
	}
	if level > f.level {
		return
	}
	if tag != "" {
		message = tag + ": " + message
	}
	if f.platformWriter != nil {
		f.platformWriter.WriteMessage(level, message)
	}
}

type factoryLogger struct {
	factory *Factory
	tag     string
}

func (l *factoryLogger) log(level Level, args []any) {
	l.factory.output(level, l.tag, F.ToString(args...))
}

func (l *factoryLogger) Trace(args ...any) {
	l.log(LevelTrace, args)
}

func (l *factoryLogger) Debug(args ...any) {
	l.log(LevelDebug, args)
}

func (l *factoryLogger) Info(args ...any) {
	l.log(LevelInfo, args)
}

func (l *factoryLogger) Warn(args ...any) {
	l.log(LevelWarn, args)
}

func (l *factoryLogger) Error(args ...any) {
	l.log(LevelError, args)
}

func (l *factoryLogger) Fatal(args ...any) {
	l.log(LevelFatal, args)
}

func (l *factoryLogger) Panic(args ...any) {
	l.log(LevelPanic, args)
}

func (l *factoryLogger) TraceContext(_ context.Context, args ...any) {
	l.log(LevelTrace, args)
}

func (l *factoryLogger) DebugContext(_ context.Context, args ...any) {
	l.log(LevelDebug, args)
}

func (l *factoryLogger) InfoContext(_ context.Context, args ...any) {
	l.log(LevelInfo, args)
}

func (l *factoryLogger) WarnContext(_ context.Context, args ...any) {
	l.log(LevelWarn, args)
}

func (l *factoryLogger) ErrorContext(_ context.Context, args ...any) {
	l.log(LevelError, args)
}

func (l *factoryLogger) FatalContext(_ context.Context, args ...any) {
	l.log(LevelFatal, args)
}

func (l *factoryLogger) PanicContext(_ context.Context, args ...any) {
	l.log(LevelPanic, args)
}
