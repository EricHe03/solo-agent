package main

import (
	"bytes"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	protoDirectory = "internal/proto"
	esDirectory    = "cli/proto"
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
	protoFiles, err := filepath.Glob(filepath.Join(protoDirectory, "*.proto"))
	if err != nil {
		log.Fatal(err)
	}
	if err = os.RemoveAll(esDirectory); err != nil {
		log.Fatal(err)
	}
	if err = os.MkdirAll(esDirectory, 0o755); err != nil {
		log.Fatal(err)
	}
	command := exec.Command("protoc", append([]string{
		"-I", protoDirectory,
		"--go_out", protoDirectory,
		"--go_opt", "paths=source_relative",
		"--go-grpc_out", protoDirectory,
		"--go-grpc_opt", "paths=source_relative",
		"--es_out", esDirectory,
		"--es_opt", "target=js,import_extension=.js",
	}, protoFiles...)...)
	command.Env = append(os.Environ(), "PATH="+strings.Join([]string{binDirectory, filepath.Join("node_modules", ".bin"), os.Getenv("PATH")}, string(os.PathListSeparator)))
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
