//go:build darwin && cgo

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"runtime/debug"
	"syscall"
	"time"

	"github.com/swipt-automation/swipt/internal/computer"
	"github.com/swipt-automation/swipt/internal/log"

	"github.com/spf13/cobra"
)

var options computer.Options

func main() {
	command := &cobra.Command{
		Use:          "swipt-server [-d NAME|UDID]",
		Short:        "Serve the Swipt API and MCP from this Mac for a device that it is paired with",
		Args:         cobra.NoArgs,
		RunE:         run,
		SilenceUsage: true,
	}
	command.Flags().StringVarP(&options.Device, "device", "d", os.Getenv("SWIPT_DEVICE"), "the device to serve, by name or UDID (SWIPT_DEVICE); needed when more than one is connected")
	if err := command.Execute(); err != nil {
		if errors.Is(err, context.Canceled) {
			os.Exit(130)
		}
		os.Exit(1)
	}
}

func run(command *cobra.Command, _ []string) error {
	options.Logs = log.NewFactory(log.Options{Level: log.LevelInfo, PlatformWriter: writer{}})
	options.Version = version()
	options.Output = command.OutOrStdout()
	ctx, stop := signal.NotifyContext(command.Context(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	err := computer.Run(ctx, options)
	if err != nil && errors.Is(err, context.Canceled) && ctx.Err() != nil {
		command.SilenceErrors = true
	}
	return err
}

func version() string {
	info, loaded := debug.ReadBuildInfo()
	if !loaded || info.Main.Version == "" {
		return "(devel)"
	}
	return info.Main.Version
}

type writer struct{}

func (writer) WriteMessage(level log.Level, message string) {
	fmt.Fprintln(os.Stderr, time.Now().Format("15:04:05.000"), levelName(level), message)
}

func levelName(level log.Level) string {
	switch level {
	case log.LevelError:
		return "ERROR"
	case log.LevelWarn:
		return "WARN"
	case log.LevelInfo:
		return "INFO"
	case log.LevelDebug:
		return "DEBUG"
	}
	return "TRACE"
}
