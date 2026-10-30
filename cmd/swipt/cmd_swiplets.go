package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/structpb"

	"github.com/spf13/cobra"
)

const uploadChunk = 256 << 10

var (
	callInput            string
	serviceWatch         bool
	filesRecursive       bool
	filesOutput          string
	filesRemoveRecursive bool
)

func init() {
	swipletsCommand := &cobra.Command{
		Use:   "swiplets [ID]",
		Short: "List the swiplets or show one",
		Args:  rangeArgs(0, 1),
		RunE:  runSwiplets,
	}
	swipletsCommand.Flags().StringVar(&sources.root, "project", "", "swiplet project for source maps")
	callCommand := &cobra.Command{
		Use:   "call ID ACTION",
		Short: "Call a swiplet action",
		Args:  exactArgs(2),
		RunE:  runCall,
	}
	callCommand.Flags().StringVar(&callInput, "input", "", "input JSON")
	callCommand.Flags().StringVar(&sources.root, "project", "", "swiplet project for source maps")
	serviceCommand := group(&cobra.Command{Use: "service", Short: "Manage swiplet services"})
	serviceCommand.PersistentFlags().StringVar(&sources.root, "project", "", "swiplet project for source maps")
	for _, enabled := range []bool{true, false} {
		name, short := "enable", "Turn on a swiplet service"
		if !enabled {
			name, short = "disable", "Turn off a swiplet service"
		}
		command := &cobra.Command{
			Use:   name + " ID",
			Short: short,
			Args:  exactArgs(1),
			RunE: func(cmd *cobra.Command, args []string) error {
				return runSetService(cmd, args[0], enabled)
			},
		}
		command.Flags().BoolVar(&serviceWatch, "watch", false, "watch the state")
		serviceCommand.AddCommand(command)
	}
	serviceCommand.AddCommand(&cobra.Command{
		Use:   "watch [ID]",
		Short: "Watch swiplet services",
		Args:  rangeArgs(0, 1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id := ""
			if len(args) > 0 {
				id = args[0]
			}
			ctx, c, end, err := session(cmd)
			if err != nil {
				return err
			}
			defer end()
			return watchServices(ctx, c, id)
		},
	})
	removeCommand := &cobra.Command{Use: "remove ID", Short: "Remove a swiplet", Args: exactArgs(1), RunE: runRemove}
	filesCommand := group(&cobra.Command{Use: "files", Short: "Manage swiplet data files"})
	listCommand := &cobra.Command{Use: "list ID [PATH]", Short: "List data files", Args: rangeArgs(1, 2), RunE: runFilesList}
	listCommand.Flags().BoolVar(&filesRecursive, "recursive", false, "include subdirectories")
	readCommand := &cobra.Command{Use: "read ID PATH", Short: "Read a data file or directory", Args: exactArgs(2), RunE: runFilesRead}
	readCommand.Flags().StringVar(&filesOutput, "output", "", "destination")
	writeCommand := &cobra.Command{Use: "write ID PATH [FILE | -]", Short: "Write a data file", Args: rangeArgs(2, 3), RunE: runFilesWrite}
	fileRemoveCommand := &cobra.Command{Use: "remove ID PATH", Short: "Remove a data file", Args: exactArgs(2), RunE: runFilesRemove}
	fileRemoveCommand.Flags().BoolVar(&filesRemoveRecursive, "recursive", false, "include directory contents")
	filesCommand.AddCommand(listCommand, readCommand, writeCommand, fileRemoveCommand)
	mainCommand.AddCommand(swipletsCommand, callCommand, serviceCommand, removeCommand, filesCommand)
}

func readInput(value string) (*structpb.Value, error) {
	if value == "" {
		return nil, nil
	}
	data := []byte(value)
	var err error
	switch {
	case value == "-":
		data, err = io.ReadAll(os.Stdin)
	case strings.HasPrefix(value, "@"):
		data, err = os.ReadFile(value[1:])
	}
	if err != nil {
		return nil, E.Cause(err, "read --input")
	}
	var parsed any
	if err = json.Unmarshal(data, &parsed); err != nil {
		return nil, usageError{E.Cause(err, "--input is not JSON")}
	}
	input, err := structpb.NewValue(parsed)
	if err != nil {
		return nil, usageError{E.Cause(err, "--input is not JSON")}
	}
	return input, nil
}

func printResult(id string, result *proto.ActionResult) error {
	switch outcome := result.GetOutcome().(type) {
	case *proto.ActionResult_Output:
		data, err := json.MarshalIndent(outcome.Output.AsInterface(), "", "  ")
		if err != nil {
			return err
		}
		_, err = os.Stdout.Write(append(data, '\n'))
		return err
	case *proto.ActionResult_Error:
		return printScriptError(outcome.Error, sources.frame(id))
	}
	return E.New("the server sent no result")
}

func notInstalled(id string) error {
	return status.Error(codes.NotFound, "there is no swiplet "+strconv.Quote(id))
}

func runSwiplets(cmd *cobra.Command, args []string) error {
	ctx, c, end, err := session(cmd)
	if err != nil {
		return err
	}
	defer end()
	response, err := c.swiplets.ListSwiplets(ctx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	swiplets := response.Swiplets
	if len(args) == 0 {
		writer := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(writer, "ID\tTITLE\tVERSION\tACTIONS\tSERVICE\tSTATUS")
		for _, swiplet := range swiplets {
			names := common.Map(swiplet.Actions, func(action *proto.SwipletAction) string { return action.Name })
			service, status := "", ""
			if state := swiplet.Service; state != nil {
				service, status = "disabled", "stopped"
				if state.Enabled {
					service = "enabled"
				}
				if state.Status != proto.ServiceStatus_SERVICE_STATUS_UNSPECIFIED {
					status = enumText(state.Status, "SERVICE_STATUS_")
				}
				if state.Error != nil {
					status += ": " + state.Error.Name + ": " + state.Error.Message
				}
			}
			fmt.Fprintln(writer, strings.Join([]string{swiplet.Id, swiplet.Title, swiplet.Version, strings.Join(names, ","), service, status}, "\t"))
		}
		return writer.Flush()
	}
	swiplet := common.Find(swiplets, func(it *proto.Swiplet) bool { return it.Id == args[0] })
	if swiplet == nil {
		return notInstalled(args[0])
	}
	fmt.Println(swiplet.Id, strconv.Quote(swiplet.Title), swiplet.Version)
	if swiplet.HasUi {
		fmt.Println("ui: yes")
	}
	if swiplet.Service != nil {
		fmt.Println("service: " + serviceText(swiplet.Id, swiplet.Service))
	}
	for _, action := range swiplet.Actions {
		fmt.Println()
		line := "action " + action.Name + " " + strconv.Quote(action.Title)
		if action.ExposedToShortcuts {
			line += " (shortcuts)"
		}
		fmt.Println(line)
		if action.Description != "" {
			fmt.Println("  " + action.Description)
		}
		if action.InputSchema != nil {
			data, _ := json.MarshalIndent(action.InputSchema.AsMap(), "  ", "  ")
			fmt.Println("  input: " + string(data))
		}
		if action.OutputSchema != nil {
			data, _ := json.MarshalIndent(action.OutputSchema.AsMap(), "  ", "  ")
			fmt.Println("  output: " + string(data))
		}
	}
	return nil
}

func runCall(cmd *cobra.Command, args []string) error {
	input, err := readInput(callInput)
	if err != nil {
		return err
	}
	ctx, c, end, err := session(cmd)
	if err != nil {
		return err
	}
	defer end()
	stream, err := c.swiplets.CallAction(ctx, &proto.CallActionRequest{SwipletId: args[0], Action: args[1], Input: input})
	if err != nil {
		return err
	}
	var result *proto.ActionResult
	for {
		response, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		switch part := response.Part.(type) {
		case *proto.CallActionResponse_Log:
			printLog(part.Log, false)
		case *proto.CallActionResponse_Result:
			result = part.Result
		}
	}
	if result == nil {
		return E.New("the server sent no result")
	}
	return printResult(args[0], result)
}

func watchServices(ctx context.Context, c *client, id string) error {
	stream, err := c.swiplets.WatchServices(ctx, &proto.WatchServicesRequest{SwipletId: id})
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
		printService(response.SwipletId, response.Service)
	}
}

func runSetService(cmd *cobra.Command, id string, enabled bool) error {
	ctx, c, end, err := session(cmd)
	if err != nil {
		return err
	}
	defer end()
	response, err := c.swiplets.SetServiceEnabled(ctx, &proto.SetServiceEnabledRequest{SwipletId: id, Enabled: enabled})
	if err != nil {
		return err
	}
	if !serviceWatch {
		printService(id, response.Service)
		return nil
	}
	return watchServices(ctx, c, id)
}

func runRemove(cmd *cobra.Command, args []string) error {
	ctx, c, end, err := session(cmd)
	if err != nil {
		return err
	}
	defer end()
	if _, err = c.swiplets.RemoveSwiplet(ctx, &proto.RemoveSwipletRequest{SwipletId: args[0]}); err != nil {
		return err
	}
	fmt.Println("removed", args[0])
	return nil
}

func runFilesList(cmd *cobra.Command, args []string) error {
	directory := ""
	if len(args) > 1 {
		directory = args[1]
	}
	ctx, c, end, err := session(cmd)
	if err != nil {
		return err
	}
	defer end()
	response, err := c.swiplets.ListDataFiles(ctx, &proto.ListDataFilesRequest{SwipletId: args[0], Path: directory, Recursive: filesRecursive})
	if err != nil {
		return err
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	for _, file := range response.Files {
		name := file.Path
		size := strconv.FormatInt(file.Size, 10)
		if file.Directory {
			name, size = name+"/", "-"
		}
		fmt.Fprintln(writer, size+"\t"+file.Modified.AsTime().Local().Format(time.DateTime)+"\t"+name)
	}
	return writer.Flush()
}

type fileSink struct {
	root  string
	files map[string]*os.File
	saved int
}

func (s *fileSink) target(name string) (string, error) {
	if !filepath.IsLocal(filepath.FromSlash(name)) {
		return "", E.New("the server sent the path ", name, ", which leaves the output directory")
	}
	return filepath.Join(s.root, filepath.FromSlash(name)), nil
}

func (s *fileSink) begin(info *proto.FileInfo) error {
	name, err := s.target(info.Path)
	if err != nil {
		return err
	}
	if info.Directory {
		return os.MkdirAll(name, 0o755)
	}
	if err = os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		return err
	}
	file, err := os.Create(name)
	if err != nil {
		return err
	}
	if previous := s.files[info.Path]; previous != nil {
		previous.Close()
	}
	s.files[info.Path] = file
	s.saved++
	return nil
}

func (s *fileSink) write(chunk *proto.FileChunk) error {
	file := s.files[chunk.Path]
	if file == nil {
		return E.New("the server sent data for ", chunk.Path, " before announcing it")
	}
	_, err := file.WriteAt(chunk.Data, chunk.Offset)
	return err
}

func (s *fileSink) close() error {
	var err error
	for _, file := range s.files {
		err = E.Errors(err, file.Close())
	}
	return err
}

func printSaved(target string, count int) {
	fmt.Fprintf(os.Stderr, "saved %d file(s) to %s\n", count, target)
}

func runFilesRead(cmd *cobra.Command, args []string) error {
	requested := strings.Trim(path.Clean("/"+args[1]), "/")
	printing := filesOutput == "" || filesOutput == "-"
	directory := func() error {
		if requested == "" {
			return usageError{E.New(strconv.Quote(args[1]), " names the data directory of ", args[0], "; save it with --output DIRECTORY")}
		}
		return usageError{E.New(strconv.Quote(requested), " is a directory in the data directory of ", args[0], "; save it with --output DIRECTORY")}
	}
	ctx, c, end, err := session(cmd)
	if err != nil {
		return err
	}
	defer end()
	stream, err := c.swiplets.ReadDataFile(ctx, &proto.ReadDataFileRequest{SwipletId: args[0], Path: args[1]})
	if err != nil {
		return err
	}
	var sink *fileSink
	var single *proto.FileInfo
	var contents []byte
	for {
		response, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		switch part := response.Part.(type) {
		case *proto.ReadDataFileResponse_File:
			info := part.File
			if info.Path == requested && !info.Directory {
				single = info
				continue
			}
			if sink == nil {
				if printing {
					return directory()
				}
				sink = &fileSink{root: filesOutput, files: make(map[string]*os.File)}
			}
			relative := strings.TrimPrefix(strings.TrimPrefix(info.Path, requested), "/")
			if err = sink.begin(&proto.FileInfo{Path: relative, Directory: info.Directory}); err != nil {
				return err
			}
		case *proto.ReadDataFileResponse_Chunk:
			chunk := part.Chunk
			if single != nil && chunk.Path == single.Path {
				contents = append(contents, chunk.Data...)
				continue
			}
			if sink == nil {
				return E.New("the server sent data for ", chunk.Path, " before announcing it")
			}
			relative := strings.TrimPrefix(strings.TrimPrefix(chunk.Path, requested), "/")
			if err = sink.write(&proto.FileChunk{Path: relative, Offset: chunk.Offset, Data: chunk.Data}); err != nil {
				return err
			}
		}
	}
	switch {
	case sink != nil:
		if err = sink.close(); err != nil {
			return err
		}
		printSaved(sink.root, sink.saved)
		return nil
	case single == nil && printing:
		return directory()
	case single == nil:
		if err = os.MkdirAll(filesOutput, 0o755); err != nil {
			return err
		}
		printSaved(filesOutput, 0)
		return nil
	case printing:
		_, err = os.Stdout.Write(contents)
		return err
	}
	target := filesOutput
	if info, err := os.Stat(target); err == nil && info.IsDir() {
		target = filepath.Join(target, path.Base(single.Path))
	}
	if err = os.WriteFile(target, contents, 0o644); err != nil {
		return err
	}
	printSaved(target, 1)
	return nil
}

func runFilesWrite(cmd *cobra.Command, args []string) error {
	var data []byte
	var err error
	if len(args) < 3 || args[2] == "-" {
		data, err = io.ReadAll(os.Stdin)
	} else {
		data, err = os.ReadFile(args[2])
	}
	if err != nil {
		return err
	}
	ctx, c, end, err := session(cmd)
	if err != nil {
		return err
	}
	defer end()
	stream, err := c.swiplets.WriteDataFile(ctx)
	if err != nil {
		return err
	}
	err = stream.Send(&proto.WriteDataFileRequest{Part: &proto.WriteDataFileRequest_Header{Header: &proto.WriteDataFileHeader{SwipletId: args[0], Path: args[1]}}})
	for offset := 0; err == nil && offset < len(data); offset += uploadChunk {
		err = stream.Send(&proto.WriteDataFileRequest{Part: &proto.WriteDataFileRequest_Data{Data: data[offset:min(offset+uploadChunk, len(data))]}})
	}
	_, err = stream.CloseAndRecv()
	return err
}

func runFilesRemove(cmd *cobra.Command, args []string) error {
	ctx, c, end, err := session(cmd)
	if err != nil {
		return err
	}
	defer end()
	request := &proto.RemoveDataFileRequest{SwipletId: args[0], Path: args[1], Recursive: filesRemoveRecursive}
	_, err = c.swiplets.RemoveDataFile(ctx, request)
	return err
}
