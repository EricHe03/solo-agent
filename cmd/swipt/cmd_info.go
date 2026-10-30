package main

import (
	"fmt"
	"os"
	"runtime"
	runtimeDebug "runtime/debug"
	"text/tabwriter"

	swiptv1 "github.com/swipt-automation/swipt/internal/api/gen/swipt/v1"

	"github.com/spf13/cobra"
)

func init() {
	mainCommand.AddCommand(
		&cobra.Command{
			Use:   "info",
			Short: "Show the device and its connection",
			Args:  exactArgs(0),
			RunE:  runInfo,
		},
		&cobra.Command{
			Use:   "version",
			Short: "Print the version",
			Args:  exactArgs(0),
			Run: func(cmd *cobra.Command, args []string) {
				version := "(devel)"
				if info, loaded := runtimeDebug.ReadBuildInfo(); loaded && info.Main.Version != "" {
					version = info.Main.Version
				}
				fmt.Println("swipt", version, runtime.Version(), runtime.GOOS+"/"+runtime.GOARCH)
			},
		},
	)
}

func runInfo(cmd *cobra.Command, _ []string) error {
	ctx, c, end, err := session(cmd)
	if err != nil {
		return err
	}
	defer end()
	info, err := c.system.GetInfo(ctx, &swiptv1.GetInfoRequest{})
	if err != nil {
		return err
	}
	connection := info.DeviceConnection
	state := enumText(connection.GetState(), "DEVICE_CONNECTION_STATE_")
	if connection.GetProblem() != swiptv1.DeviceConnectionProblem_DEVICE_CONNECTION_PROBLEM_UNSPECIFIED {
		state += ", " + enumText(connection.GetProblem(), "DEVICE_CONNECTION_PROBLEM_")
	}
	if connection.GetMessage() != "" {
		state += ": " + connection.GetMessage()
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	for _, row := range [][2]string{
		{"device", info.DeviceName},
		{"udid", info.Udid},
		{"server", info.ServerVersion},
		{"connection", state},
	} {
		fmt.Fprintln(writer, row[0]+":\t"+row[1])
	}
	return writer.Flush()
}
