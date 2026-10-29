package log

import (
	"context"
	"fmt"
	"io"
	"strings"
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

type Options struct {
	Level          Level
	Writer         io.Writer
	PlatformWriter PlatformWriter
}

const entryCapacity = 4096

type Factory struct {
	baseTime       time.Time
	level          Level
	writer         io.Writer
	platformWriter PlatformWriter

	access  sync.Mutex
	entries []Entry
	start   int
}

func NewFactory(options Options) *Factory {
	return &Factory{
		baseTime:       time.Now(),
		level:          options.Level,
		writer:         options.Writer,
		platformWriter: options.PlatformWriter,
	}
}

func (f *Factory) SetLevel(level Level) {
	f.level = level
}

func (f *Factory) Logger() ContextLogger {
	return f.NewLogger("")
}

func (f *Factory) NewLogger(tag string) ContextLogger {
	return &factoryLogger{factory: f, tag: tag}
}

func (f *Factory) Entries(since time.Time, level Level) []Entry {
	f.access.Lock()
	defer f.access.Unlock()
	var entries []Entry
	for _, part := range [][]Entry{f.entries[f.start:], f.entries[:f.start]} {
		for _, entry := range part {
			if entry.Level <= level && !entry.Time.Before(since) {
				entries = append(entries, entry)
			}
		}
	}
	return entries
}

func (f *Factory) output(entry Entry) {
	f.access.Lock()
	if len(f.entries) < entryCapacity {
		f.entries = append(f.entries, entry)
	} else {
		f.entries[f.start] = entry
		f.start = (f.start + 1) % entryCapacity
	}
	f.access.Unlock()
	if entry.Level > f.level {
		return
	}
	message := entry.Message
	if entry.Tag != "" {
		message = entry.Tag + ": " + message
	}
	if f.writer != nil {
		fmt.Fprintf(f.writer, "%s[%04d] %s\n", strings.ToUpper(FormatLevel(entry.Level)), int64(entry.Time.Sub(f.baseTime)/time.Second), message)
	}
	if f.platformWriter != nil {
		f.platformWriter.WriteMessage(entry.Level, message)
	}
}

type factoryLogger struct {
	factory *Factory
	tag     string
}

func (l *factoryLogger) log(level Level, args []any) {
	l.factory.output(Entry{Time: time.Now(), Level: level, Tag: l.tag, Message: F.ToString(args...)})
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
