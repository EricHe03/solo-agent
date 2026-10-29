//go:build darwin && !ios

package main

import (
	"log/slog"
	"os"

	"github.com/swipt-automation/swipt/internal/logbuffer"

	"github.com/spf13/cobra"
)

var (
	debugLog bool
	logLevel slog.LevelVar
	logs     = logbuffer.New()
	logger   = slog.New(logs.Handler(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: &logLevel})))
)

var mainCommand = &cobra.Command{
	Use:              "iOS-server",
	Short:            "Serve an iPhone or iPad connected to this Mac to Screen Sharing viewers and MCP clients",
	PersistentPreRun: preRun,
	SilenceErrors:    true,
}

func init() {
	mainCommand.PersistentFlags().BoolVar(&debugLog, "debug", false, "print debug logs")
}

func preRun(cmd *cobra.Command, args []string) {
	if debugLog {
		logLevel.Set(slog.LevelDebug)
	}
}

func fatal(err error) {
	logger.Error(err.Error())
	os.Exit(1)
}
