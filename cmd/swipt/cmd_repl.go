package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	swiptv1 "github.com/swipt-automation/swipt/internal/api/gen/swipt/v1"
	"github.com/swipt-automation/swipt/internal/automation/declarations"

	"github.com/spf13/cobra"
)

const scriptGrace = 10 * time.Second

var (
	jsFile   string
	jsReset  bool
	jsAPI    bool
	jsOutput string
)

func init() {
	jsCommand := &cobra.Command{
		Use:   "js [CODE | -]",
		Short: "Run JavaScript on the device",
		Args:  rangeArgs(0, 1),
		RunE:  runJS,
	}
	flags := jsCommand.Flags()
	flags.StringVar(&jsFile, "file", "", "script file")
	flags.BoolVar(&jsReset, "reset", false, "reset the session first")
	flags.BoolVar(&jsAPI, "api", false, "TypeScript declarations")
	flags.StringVar(&jsOutput, "output", "", "image directory")
	mainCommand.AddCommand(jsCommand)
}

func readScript(args []string) (string, bool, error) {
	switch {
	case len(args) == 1 && jsFile != "":
		return "", false, usageError{E.New("give CODE or --file, not both")}
	case jsFile != "":
		data, err := os.ReadFile(jsFile)
		return string(data), true, err
	case len(args) == 1 && args[0] != "-":
		return args[0], true, nil
	case len(args) == 0 && jsReset:
		return "", false, nil
	}
	data, err := io.ReadAll(os.Stdin)
	return string(data), true, err
}

type imageSink struct {
	directory string
}

func (s *imageSink) save(data []byte) (string, error) {
	if s.directory == "" {
		var err error
		if jsOutput != "" {
			s.directory, err = filepath.Abs(jsOutput)
			if err == nil {
				err = os.MkdirAll(s.directory, 0o755)
			}
		} else {
			s.directory, err = os.MkdirTemp("", "swipt-js-")
		}
		if err != nil {
			return "", err
		}
	}
	file, err := os.CreateTemp(s.directory, "image-*.png")
	if err != nil {
		return "", err
	}
	_, err = file.Write(data)
	return file.Name(), E.Errors(err, file.Close())
}

func runJS(cmd *cobra.Command, args []string) error {
	if jsAPI {
		if len(args) > 0 || jsFile != "" || jsReset {
			return usageError{E.New("--api takes no script and no --reset")}
		}
		fmt.Print(declarations.TypeScript)
		return nil
	}
	code, run, err := readScript(args)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(cmd.Context())
	if globalTimeout > 0 {
		ctx, cancel = context.WithTimeout(cmd.Context(), globalTimeout+scriptGrace)
	}
	defer cancel()
	c, err := open()
	if err != nil {
		return err
	}
	defer c.close()
	if jsReset {
		if _, err = c.repl.Reset(ctx, &swiptv1.ResetRequest{}); err != nil {
			return err
		}
	}
	if !run {
		return nil
	}
	stream, err := c.repl.Execute(ctx, &swiptv1.ExecuteRequest{Code: code, TimeoutMs: uint32(globalTimeout.Milliseconds())})
	if err != nil {
		return err
	}
	script := "input.js"
	if jsFile != "" {
		script = jsFile
	}
	images := &imageSink{}
	var failure *swiptv1.ScriptError
	for {
		response, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		switch part := response.Part.(type) {
		case *swiptv1.ExecuteResponse_Console:
			printConsole(part.Console)
		case *swiptv1.ExecuteResponse_Value:
			fmt.Println(part.Value.Text)
		case *swiptv1.ExecuteResponse_Image:
			path, err := images.save(part.Image)
			if err != nil {
				return err
			}
			fmt.Println("[image: " + path + "]")
		case *swiptv1.ExecuteResponse_Error:
			failure = part.Error
		}
	}
	if failure == nil {
		return nil
	}
	return printScriptError(failure, func(frame *swiptv1.StackFrame) *swiptv1.StackFrame {
		if frame.File != "input.js" {
			return frame
		}
		return &swiptv1.StackFrame{Function: frame.Function, File: script, Line: frame.Line, Column: frame.Column}
	})
}

func printConsole(output *swiptv1.ConsoleOutput) {
	if output.Level == swiptv1.LogLevel_LOG_LEVEL_ERROR || output.Level == swiptv1.LogLevel_LOG_LEVEL_WARN {
		fmt.Fprintln(os.Stderr, output.Text)
		return
	}
	fmt.Println(output.Text)
}
