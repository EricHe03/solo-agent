package api

import (
	"context"

	"github.com/swipt-automation/swipt/internal/log"
	"github.com/swipt-automation/swipt/internal/proto"

	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/timestamppb"
)

const logBuffer = 1024

type logService struct {
	proto.UnimplementedLogServiceServer
	*Server
}

func logLevel(level log.Level) proto.LogLevel {
	switch {
	case level <= log.LevelError:
		return proto.LogLevel_LOG_LEVEL_ERROR
	case level == log.LevelWarn:
		return proto.LogLevel_LOG_LEVEL_WARN
	case level == log.LevelInfo:
		return proto.LogLevel_LOG_LEVEL_INFO
	}
	return proto.LogLevel_LOG_LEVEL_DEBUG
}

func logEntry(entry log.Entry) *proto.LogEntry {
	return &proto.LogEntry{Time: timestamppb.New(entry.Time), Level: logLevel(entry.Level), Tag: entry.Tag, Message: entry.Message}
}

func (s *logService) ReadLogs(filter *proto.ReadLogsRequest, stream grpc.ServerStreamingServer[proto.ReadLogsResponse]) error {
	ctx := stream.Context()
	matches := func(entry log.Entry) bool {
		if filter.Level != proto.LogLevel_LOG_LEVEL_UNSPECIFIED && logLevel(entry.Level) > filter.Level {
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
		if err := stream.Send(&proto.ReadLogsResponse{Entry: logEntry(entry)}); err != nil {
			return err
		}
	}
	if !filter.Follow {
		return nil
	}
	for {
		select {
		case entry := <-received:
			if err := stream.Send(&proto.ReadLogsResponse{Entry: logEntry(entry)}); err != nil {
				return err
			}
		case <-ctx.Done():
			return context.Cause(ctx)
		}
	}
}
