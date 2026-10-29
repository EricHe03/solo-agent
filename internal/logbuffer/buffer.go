package logbuffer

import (
	"context"
	"log/slog"
	"slices"
	"sync"
	"time"
)

type Attr struct {
	Key   string
	Value string
}

type Record struct {
	Time    time.Time
	Level   slog.Level
	Message string
	Attrs   []Attr
}

type Buffer struct {
	access  sync.Mutex
	records []Record
	start   int
}

const capacity = 4096

func New() *Buffer {
	return &Buffer{records: make([]Record, 0, capacity)}
}

func (b *Buffer) add(record Record) {
	b.access.Lock()
	defer b.access.Unlock()
	if len(b.records) < cap(b.records) {
		b.records = append(b.records, record)
		return
	}
	b.records[b.start] = record
	b.start = (b.start + 1) % len(b.records)
}

func (b *Buffer) Records(since time.Time, level slog.Level) []Record {
	b.access.Lock()
	defer b.access.Unlock()
	var out []Record
	for _, part := range [][]Record{b.records[b.start:], b.records[:b.start]} {
		for _, record := range part {
			if record.Level >= level && !record.Time.Before(since) {
				out = append(out, record)
			}
		}
	}
	return out
}

func (b *Buffer) Handler(next slog.Handler) slog.Handler {
	return &handler{buffer: b, next: next}
}

type handler struct {
	buffer *Buffer
	next   slog.Handler
	group  string
	attrs  []Attr
}

func (h *handler) Enabled(context.Context, slog.Level) bool {
	return true
}

func (h *handler) Handle(ctx context.Context, record slog.Record) error {
	attrs := slices.Clone(h.attrs)
	record.Attrs(func(attr slog.Attr) bool {
		attrs = appendAttr(attrs, h.group, attr)
		return true
	})
	h.buffer.add(Record{Time: record.Time, Level: record.Level, Message: record.Message, Attrs: attrs})
	if !h.next.Enabled(ctx, record.Level) {
		return nil
	}
	return h.next.Handle(ctx, record)
}

func (h *handler) WithAttrs(attrs []slog.Attr) slog.Handler {
	out := slices.Clone(h.attrs)
	for _, attr := range attrs {
		out = appendAttr(out, h.group, attr)
	}
	return &handler{buffer: h.buffer, next: h.next.WithAttrs(attrs), group: h.group, attrs: out}
}

func (h *handler) WithGroup(name string) slog.Handler {
	if name == "" {
		return h
	}
	return &handler{buffer: h.buffer, next: h.next.WithGroup(name), group: h.group + name + ".", attrs: h.attrs}
}

func appendAttr(attrs []Attr, group string, attr slog.Attr) []Attr {
	value := attr.Value.Resolve()
	if value.Kind() == slog.KindGroup {
		if attr.Key != "" {
			group += attr.Key + "."
		}
		for _, member := range value.Group() {
			attrs = appendAttr(attrs, group, member)
		}
		return attrs
	}
	if attr.Key == "" {
		return attrs
	}
	return append(attrs, Attr{Key: group + attr.Key, Value: value.String()})
}
