package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

var (
	globalHost    string
	globalToken   string
	globalTimeout time.Duration
)

var mainCommand = group(&cobra.Command{
	Use:           "swipt",
	Short:         "Operate a device through Swipt",
	SilenceErrors: true,
	SilenceUsage:  true,
})

type usageError struct {
	error
}

type falseResult struct{}

func (falseResult) Error() string { return "false" }

func init() {
	flags := mainCommand.PersistentFlags()
	flags.StringVar(&globalHost, "host", "", "Swipt URL (SWIPT_HOST)")
	flags.StringVar(&globalToken, "token", "", "API token (SWIPT_TOKEN)")
	flags.DurationVar(&globalTimeout, "timeout", 0, "time limit")
	flags.Bool("help", false, "help")
	mainCommand.SetFlagErrorFunc(func(_ *cobra.Command, err error) error {
		if errors.Is(err, pflag.ErrHelp) {
			return err
		}
		return usageError{err}
	})
}

func group(cmd *cobra.Command) *cobra.Command {
	cmd.Args = cobra.ArbitraryArgs
	cmd.SuggestionsMinimumDistance = 2
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if len(args) == 0 {
			return cmd.Help()
		}
		message := "unknown command " + strconv.Quote(args[0]) + " for " + strconv.Quote(cmd.CommandPath())
		if suggestions := cmd.SuggestionsFor(args[0]); len(suggestions) > 0 {
			message += "; did you mean " + strings.Join(suggestions, " or ") + "?"
		}
		return usageError{E.New(message)}
	}
	return cmd
}

func exactArgs(count int) cobra.PositionalArgs {
	return func(cmd *cobra.Command, args []string) error {
		if err := cobra.ExactArgs(count)(cmd, args); err != nil {
			return usageError{err}
		}
		return nil
	}
}

func rangeArgs(least, most int) cobra.PositionalArgs {
	return func(cmd *cobra.Command, args []string) error {
		if err := cobra.RangeArgs(least, most)(cmd, args); err != nil {
			return usageError{err}
		}
		return nil
	}
}

func commandContext(cmd *cobra.Command) (context.Context, context.CancelFunc) {
	if globalTimeout == 0 {
		return context.WithCancel(cmd.Context())
	}
	return context.WithTimeout(cmd.Context(), globalTimeout)
}

func session(cmd *cobra.Command) (context.Context, *client, func(), error) {
	ctx, cancel := commandContext(cmd)
	c, err := open()
	if err != nil {
		cancel()
		return nil, nil, nil, err
	}
	return ctx, c, func() {
		c.close()
		cancel()
	}, nil
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := mainCommand.ExecuteContext(ctx)
	interrupted := ctx.Err() != nil
	stop()
	if err != nil {
		os.Exit(report(err, interrupted))
	}
}

func printError(err error) int {
	exit, message := 1, err.Error()
	if usage, isUsage := errors.AsType[usageError](err); isUsage {
		exit, message = 2, usage.Error()
	} else if errors.Is(err, context.DeadlineExceeded) || status.Code(err) == codes.DeadlineExceeded {
		if globalTimeout > 0 {
			message = "the command ran past --timeout " + globalTimeout.String()
		}
	} else if reply, isStatus := status.FromError(err); isStatus {
		message = reply.Message()
		switch reply.Code() {
		case codes.Unavailable:
			exit, message = 5, "Swipt at "+globalHost+" is unreachable: "+reply.Message()
		case codes.Unauthenticated:
			message = reply.Message() + "; copy the token from Swipt › Developer"
		case codes.Unimplemented:
			message = "Swipt at " + globalHost + " does not have this command; update Swipt"
		}
	}
	fmt.Fprintln(os.Stderr, "error:", message)
	if exit == 2 {
		fmt.Fprintln(os.Stderr, `run "swipt help" for usage`)
	}
	return exit
}

func report(err error, interrupted bool) int {
	if errors.Is(err, falseResult{}) {
		return 1
	}
	if interrupted {
		return 130
	}
	return printError(err)
}
