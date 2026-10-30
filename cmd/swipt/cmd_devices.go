package main

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"
)

const browseLimit = 1500 * time.Millisecond

type bonjourService struct {
	name string
	host string
	port uint16
}

func init() {
	mainCommand.AddCommand(&cobra.Command{
		Use:   "devices",
		Short: "List the devices that publish Swipt on the local network",
		Args:  exactArgs(0),
		RunE:  runDevices,
	})
}

func runDevices(cmd *cobra.Command, _ []string) error {
	ctx, cancel := commandContext(cmd)
	defer cancel()
	services, err := browseBonjour(ctx, browseLimit)
	if err != nil {
		return err
	}
	if len(services) == 0 {
		fmt.Fprintln(os.Stderr, "no device publishes Swipt on the local network; turn on Swipt › Developer › Local Network")
		return nil
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(writer, "NAME\tHOST")
	for _, service := range services {
		fmt.Fprintln(writer, service.name+"\thttp://"+net.JoinHostPort(service.host, strconv.Itoa(int(service.port))))
	}
	return writer.Flush()
}
