package main

import (
	"bytes"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
)

func main() {
	output, err := exec.Command("go", "env", "GOBIN", "GOPATH").Output()
	if err != nil {
		log.Fatal(E.Cause(err, "read go env"))
	}
	environment := strings.Split(string(output), "\n")
	binDirectory := environment[0]
	if binDirectory == "" {
		binDirectory = filepath.Join(filepath.SplitList(environment[1])[0], "bin")
	}
	var protoFiles []string
	err = filepath.WalkDir(".", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if path != "." && (strings.HasPrefix(entry.Name(), ".") || entry.Name() == "node_modules" || path == "build") {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(path, ".proto") {
			protoFiles = append(protoFiles, path)
		}
		return nil
	})
	if err != nil {
		log.Fatal(err)
	}
	command := exec.Command("protoc", append([]string{
		"-I", ".",
		"--go_out", ".",
		"--go_opt", "paths=source_relative",
		"--go-grpc_out", ".",
		"--go-grpc_opt", "paths=source_relative",
	}, protoFiles...)...)
	command.Env = append(os.Environ(), "PATH="+binDirectory+string(os.PathListSeparator)+os.Getenv("PATH"))
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	err = command.Run()
	if err != nil {
		log.Fatal(E.Cause(err, "run protoc"))
	}
	for _, protoFile := range protoFiles {
		for _, suffix := range []string{".pb.go", "_grpc.pb.go"} {
			path := strings.TrimSuffix(protoFile, ".proto") + suffix
			content, err := os.ReadFile(path)
			if os.IsNotExist(err) {
				continue
			} else if err != nil {
				log.Fatal(err)
			}
			index := bytes.Index(content, []byte("\npackage "))
			if index < 0 {
				log.Fatal("missing package clause in ", path)
			}
			err = os.WriteFile(path, content[index+1:], 0o644)
			if err != nil {
				log.Fatal(err)
			}
		}
	}
}
