package api

import (
	"context"

	swiptv1 "github.com/swipt-automation/swipt/internal/api/gen/swipt/v1"
	"github.com/swipt-automation/swipt/internal/log"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/timestamppb"
)

const logBuffer = 1024

type logService struct {
	swiptv1.UnimplementedLogServiceServer
	*Server
}

func logLevel(level log.Level) swiptv1.LogLevel {
	switch {
	case level <= log.LevelError:
		return swiptv1.LogLevel_LOG_LEVEL_ERROR
	case level == log.LevelWarn:
		return swiptv1.LogLevel_LOG_LEVEL_WARN
	case level == log.LevelInfo:
		return swiptv1.LogLevel_LOG_LEVEL_INFO
	}
	return swiptv1.LogLevel_LOG_LEVEL_DEBUG
}

func logEntry(entry log.Entry) *swiptv1.LogEntry {
	return &swiptv1.LogEntry{Time: timestamppb.New(entry.Time), Level: logLevel(entry.Level), Tag: entry.Tag, Message: entry.Message}
}

func (s *logService) ReadLogs(filter *swiptv1.ReadLogsRequest, stream grpc.ServerStreamingServer[swiptv1.ReadLogsResponse]) error {
	ctx := stream.Context()
	matches := func(entry log.Entry) bool {
		if filter.Level != swiptv1.LogLevel_LOG_LEVEL_UNSPECIFIED && logLevel(entry.Level) > filter.Level {
			return false
		}
		if filter.SwipletId != "" && entry.Tag != "swiplet/"+filter.SwipletId {
			return false
		}
		return filter.Since == nil || !entry.Time.Before(filter.Since.AsTime())
	}
	received := make(chan log.Entry, logBuffer)
	backlog, cancel := s.options.Logs.Subscribe(func(entry log.Entry) {
		if !filter.Follow || !matches(entry) {
			return
		}
		select {
		case received <- entry:
		default:
		}
	})
	defer cancel()
	var history []log.Entry
	for _, entry := range backlog {
		if matches(entry) {
			history = append(history, entry)
		}
	}
	history = history[max(len(history)-int(filter.Tail), 0):]
	for _, entry := range history {
		if err := stream.Send(&swiptv1.ReadLogsResponse{Entry: logEntry(entry)}); err != nil {
			return err
		}
	}
	if !filter.Follow {
		return nil
	}
	for {
		select {
		case entry := <-received:
			if err := stream.Send(&swiptv1.ReadLogsResponse{Entry: logEntry(entry)}); err != nil {
				return err
			}
		case <-ctx.Done():
			return context.Cause(ctx)
		}
	}
}
