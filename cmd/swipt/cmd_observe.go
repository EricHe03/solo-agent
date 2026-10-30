package main

import (
	"errors"
	"io"
	"math"
	"slices"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	swiptv1 "github.com/swipt-automation/swipt/internal/api/gen/swipt/v1"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/spf13/cobra"
)

var (
	logsFollow  bool
	logsTail    uint32
	logsSince   time.Duration
	logsLevel   string
	logsSwiplet string
)

func init() {
	logsCommand := &cobra.Command{Use: "logs", Short: "Print the logs", Args: exactArgs(0), RunE: runLogs}
	flags := logsCommand.Flags()
	flags.BoolVar(&logsFollow, "follow", false, "follow new entries")
	flags.Uint32Var(&logsTail, "tail", 100, "number of past entries")
	flags.DurationVar(&logsSince, "since", 0, "maximum age")
	flags.StringVar(&logsLevel, "level", "info", "minimum level")
	flags.StringVar(&logsSwiplet, "swiplet", "", "swiplet ID")
	mainCommand.AddCommand(logsCommand)
}

func runLogs(cmd *cobra.Command, _ []string) error {
	request := &swiptv1.ReadLogsRequest{Follow: logsFollow, Tail: logsTail, SwipletId: logsSwiplet}
	levels := []string{"error", "warn", "info", "debug"}
	index := slices.Index(levels, logsLevel)
	if index < 0 {
		return usageError{E.New("--level is error, warn, info or debug")}
	}
	request.Level = swiptv1.LogLevel(index + 1)
	if logsSince > 0 {
		request.Since = timestamppb.New(time.Now().Add(-logsSince))
		if !cmd.Flags().Changed("tail") {
			request.Tail = math.MaxUint32
		}
	}
	ctx, c, end, err := session(cmd)
	if err != nil {
		return err
	}
	defer end()
	stream, err := c.logs.ReadLogs(ctx, request)
	if err != nil {
		return err
	}
	for {
		response, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		printLog(response.Entry, true)
	}
}
