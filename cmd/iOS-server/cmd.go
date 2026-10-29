//go:build darwin && !ios

package main

import (
	"os"

	"github.com/swipt-automation/swipt/internal/log"

	"github.com/spf13/cobra"
)

var (
	debugLog   bool
	logFactory = log.NewFactory(log.Options{Level: log.LevelInfo, Writer: os.Stderr})
	logger     = logFactory.Logger()
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
		logFactory.SetLevel(log.LevelDebug)
	}
}

func fatal(err error) {
	logger.Error(err)
	os.Exit(1)
}
