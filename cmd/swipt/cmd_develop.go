package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/fsnotify/fsnotify"
	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/spf13/cobra"
)

const (
	rebuildDelay  = 300 * time.Millisecond
	logReconnect  = 2 * time.Second
	projectConfig = "package.json"
)

var developNoLogs bool

func init() {
	deployCommand := &cobra.Command{
		Use:   "deploy [ARCHIVE | PROJECT]",
		Short: "Build and install a swiplet",
		Args:  rangeArgs(0, 1),
		RunE:  runDeploy,
	}
	developCommand := &cobra.Command{
		Use:   "develop [PROJECT]",
		Short: "Build, install and follow a swiplet project as it changes",
		Args:  rangeArgs(0, 1),
		RunE:  runDevelop,
	}
	developCommand.Flags().BoolVar(&developNoLogs, "no-logs", false, "without logs")
	mainCommand.AddCommand(deployCommand, developCommand)
}

type project struct {
	root string
	id   string
}

func loadProject(directory string) (project, error) {
	root, err := filepath.Abs(directory)
	if err != nil {
		return project{}, err
	}
	data, err := os.ReadFile(filepath.Join(root, projectConfig))
	if err != nil {
		return project{}, E.Cause(err, "read the project")
	}
	var manifest struct {
		Swiplet struct {
			ID string `json:"id"`
		} `json:"swiplet"`
	}
	if err = json.Unmarshal(data, &manifest); err != nil {
		return project{}, E.Cause(err, "read ", filepath.Join(root, projectConfig))
	}
	if manifest.Swiplet.ID == "" {
		return project{}, E.New(filepath.Join(root, projectConfig), " has no swiplet.id")
	}
	return project{root: root, id: manifest.Swiplet.ID}, nil
}

func (p project) archive() string {
	return filepath.Join(p.root, "dist", p.id+".swiplet")
}

type buildError struct {
	output string
}

func (e buildError) Error() string {
	return "swiplet build failed:\n" + e.output
}

func buildProject(ctx context.Context, p project) error {
	tool := filepath.Join(p.root, "node_modules", ".bin", "swiplet")
	if _, err := os.Stat(tool); err != nil {
		return E.New(tool, " is missing; install the project's dependencies")
	}
	command := exec.CommandContext(ctx, tool, "build")
	command.Dir = p.root
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	err := command.Run()
	if _, exited := errors.AsType[*exec.ExitError](err); exited && ctx.Err() == nil {
		return buildError{strings.TrimSpace(output.String())}
	}
	return err
}

func deploy(ctx context.Context, c *client, archive string) (*proto.DeploySwipletResponse, error) {
	data, err := os.ReadFile(archive)
	if err != nil {
		return nil, err
	}
	stream, err := c.swiplets.DeploySwiplet(ctx)
	if err != nil {
		return nil, err
	}
	for offset := 0; offset < len(data) || offset == 0; offset += uploadChunk {
		if err = stream.Send(&proto.DeploySwipletRequest{Chunk: data[offset:min(offset+uploadChunk, len(data))]}); err != nil {
			break
		}
	}
	return stream.CloseAndRecv()
}

func printDeployed(deployed *proto.DeploySwipletResponse, output io.Writer) {
	verb := "installed"
	if deployed.Replaced {
		verb = "replaced"
	}
	fmt.Fprintln(output, verb, deployed.Swiplet.Id, deployed.Swiplet.Version)
}

func runDeploy(cmd *cobra.Command, args []string) error {
	archive := ""
	if len(args) > 0 && (strings.HasSuffix(args[0], ".swiplet") || strings.HasSuffix(args[0], ".zip")) {
		archive = args[0]
		if _, err := os.Stat(archive); errors.Is(err, fs.ErrNotExist) {
			return E.New("there is no archive at ", archive)
		} else if err != nil {
			return err
		}
	} else {
		directory := "."
		if len(args) > 0 {
			directory = args[0]
		}
		p, err := loadProject(directory)
		if err != nil {
			return err
		}
		if err = buildProject(cmd.Context(), p); err != nil {
			return err
		}
		archive = p.archive()
	}
	ctx, c, end, err := session(cmd)
	if err != nil {
		return err
	}
	defer end()
	deployed, err := deploy(ctx, c, archive)
	if err != nil {
		return err
	}
	printDeployed(deployed, os.Stdout)
	return nil
}

func archiveDigest(name string) (string, error) {
	reader, err := zip.OpenReader(name)
	if err != nil {
		return "", err
	}
	defer reader.Close()
	files := common.Filter(reader.File, func(file *zip.File) bool { return !file.FileInfo().IsDir() })
	common.SortBy(files, func(file *zip.File) string { return file.Name })
	hash := sha256.New()
	for _, file := range files {
		hash.Write([]byte(file.Name + "\x00"))
		content, err := file.Open()
		if err != nil {
			return "", err
		}
		_, err = io.Copy(hash, content)
		content.Close()
		if err != nil {
			return "", err
		}
		hash.Write([]byte{0})
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func unauthenticated(err error) bool {
	return status.Code(err) == codes.Unauthenticated
}

func followLogs(ctx context.Context, c *client, id string, fatal chan<- error) {
	for ctx.Err() == nil {
		stream, err := c.logs.ReadLogs(ctx, &proto.ReadLogsRequest{SwipletId: id, Follow: true})
		for err == nil {
			var response *proto.ReadLogsResponse
			response, err = stream.Recv()
			if err == nil {
				printLog(response.Entry, false)
			}
		}
		if unauthenticated(err) {
			fatal <- err
			return
		}
		select {
		case <-ctx.Done():
		case <-time.After(logReconnect):
		}
	}
}

func followFailures(ctx context.Context, c *client, id string, fatal chan<- error) {
	for ctx.Err() == nil {
		stream, err := c.swiplets.WatchServices(ctx, &proto.WatchServicesRequest{})
		for err == nil {
			var response *proto.WatchServicesResponse
			response, err = stream.Recv()
			if err == nil && response.SwipletId == id && response.Service.GetStatus() == proto.ServiceStatus_SERVICE_STATUS_FAILED {
				fmt.Fprintln(os.Stderr, id+": "+serviceText(id, response.Service))
			}
		}
		if unauthenticated(err) {
			fatal <- err
			return
		}
		select {
		case <-ctx.Done():
		case <-time.After(logReconnect):
		}
	}
}

func watchProject(watcher *fsnotify.Watcher, root, start string, ignore *ignorer) error {
	return filepath.WalkDir(start, func(name string, entry fs.DirEntry, err error) error {
		if err != nil || !entry.IsDir() {
			return nil
		}
		if relative := relativePath(root, name); relative != "" && ignore.ignored(relative, true) {
			return filepath.SkipDir
		}
		return watcher.Add(name)
	})
}

type developer struct {
	ctx      context.Context
	client   *client
	root     string
	deployed string
}

func (d *developer) cycle() error {
	started := time.Now()
	p, err := loadProject(d.root)
	if err == nil {
		err = buildProject(d.ctx, p)
	}
	if failed, isBuild := errors.AsType[buildError](err); isBuild {
		fmt.Fprintln(os.Stderr, "error:", failed.Error())
		return nil
	}
	var digest string
	if err == nil {
		sources.forget(p.id)
		digest, err = archiveDigest(p.archive())
	}
	if err != nil {
		if d.ctx.Err() == nil {
			printError(err)
		}
		return nil
	}
	if digest == d.deployed {
		fmt.Fprintf(os.Stderr, "built in %s; it came out as deployed, so nothing was deployed\n", time.Since(started).Round(time.Millisecond))
		return nil
	}
	deployed, err := deploy(d.ctx, d.client, p.archive())
	switch {
	case unauthenticated(err):
		return err
	case err != nil && d.ctx.Err() == nil:
		printError(E.Cause(err, "deploy"))
		return nil
	case err != nil:
		return nil
	}
	d.deployed = digest
	printDeployed(deployed, os.Stderr)
	fmt.Fprintf(os.Stderr, "built and deployed in %s; watching %s\n", time.Since(started).Round(time.Millisecond), d.root)
	return nil
}

func runDevelop(cmd *cobra.Command, args []string) error {
	directory := "."
	if len(args) > 0 {
		directory = args[0]
	}
	p, err := loadProject(directory)
	if err != nil {
		return err
	}
	sources.root = p.root
	ctx, c, end, err := session(cmd)
	if err != nil {
		return err
	}
	defer end()
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	defer watcher.Close()
	ignore := loadIgnorer(p.root)
	if err = watchProject(watcher, p.root, p.root, ignore); err != nil {
		return err
	}
	fatal := make(chan error, 2)
	go followFailures(ctx, c, p.id, fatal)
	if !developNoLogs {
		go followLogs(ctx, c, p.id, fatal)
	}
	d := &developer{ctx: ctx, client: c, root: p.root}
	if err = d.cycle(); err != nil {
		return err
	}
	timer := time.NewTimer(time.Hour)
	timer.Stop()
	for {
		select {
		case event := <-watcher.Events:
			if filepath.Base(event.Name) == ".gitignore" {
				ignore = loadIgnorer(p.root)
			}
			info, statErr := os.Stat(event.Name)
			isDirectory := statErr == nil && info.IsDir()
			relative := relativePath(p.root, event.Name)
			if relative == "" || event.Op == fsnotify.Chmod || ignore.ignored(relative, isDirectory) {
				continue
			}
			if event.Has(fsnotify.Create) && isDirectory {
				_ = watchProject(watcher, p.root, event.Name, ignore)
			}
			timer.Reset(rebuildDelay)
		case err := <-watcher.Errors:
			printError(E.Cause(err, "watch the project"))
		case <-timer.C:
			if err = d.cycle(); err != nil {
				return err
			}
		case err := <-fatal:
			return err
		case <-ctx.Done():
			return context.Cause(ctx)
		}
	}
}
