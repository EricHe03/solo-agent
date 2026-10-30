//go:build darwin && cgo

package automation

import (
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/jsc"
)

func writeAtomically(path string, data []byte) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".write-*")
	if err != nil {
		return err
	}
	_, err = file.Write(data)
	err = E.Errors(err, file.Close())
	if err == nil {
		err = os.Rename(file.Name(), path)
	}
	if err != nil {
		_ = os.Remove(file.Name())
	}
	return err
}

func copyFile(source, destination string) error {
	return filepath.WalkDir(source, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		target := filepath.Join(destination, relative)
		if entry.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		in, err := os.Open(path)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.Create(target)
		if err != nil {
			return err
		}
		_, err = io.Copy(out, in)
		return E.Errors(err, out.Close())
	})
}

func (e *engine) file(arguments []jsc.Value) (any, error) {
	values, err := texts(arguments, 2)
	if err != nil {
		return nil, err
	}
	operation, path := values[0], values[1]
	if !filepath.IsAbs(path) {
		return nil, E.New("the path ", path, " is not absolute")
	}
	switch operation {
	case "stat":
		info, err := os.Stat(path)
		out := map[string]any{"kind": "", "size": 0, "modified": 0}
		if err == nil {
			out["kind"] = "file"
			if info.IsDir() {
				out["kind"] = "directory"
			}
			out["size"], out["modified"] = info.Size(), info.ModTime().UnixMilli()
		} else if !errors.Is(err, fs.ErrNotExist) {
			return nil, err
		}
		data, err := json.Marshal(out)
		return string(data), err
	case "read":
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		return jsc.Bytes(data), nil
	case "write":
		if len(arguments) < 3 {
			return nil, E.New("expected the contents")
		}
		data, isBytes := arguments[2].Bytes()
		if !isBytes {
			return nil, E.New("the contents are not a Uint8Array")
		}
		if err = os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return nil, err
		}
		return nil, writeAtomically(path, data)
	case "mkdir":
		intermediates := len(arguments) > 2 && arguments[2].Number() != 0
		if intermediates {
			return nil, os.MkdirAll(path, 0o755)
		}
		return nil, os.Mkdir(path, 0o755)
	case "remove":
		return nil, os.RemoveAll(path)
	case "list":
		entries, err := os.ReadDir(path)
		if err != nil {
			return nil, err
		}
		type entry struct {
			Name      string `json:"name"`
			Directory bool   `json:"directory"`
		}
		out := make([]entry, 0, len(entries))
		for _, item := range entries {
			out = append(out, entry{Name: item.Name(), Directory: item.IsDir()})
		}
		data, err := json.Marshal(out)
		return string(data), err
	case "copy", "move":
		if len(arguments) < 3 {
			return nil, E.New("expected the destination")
		}
		destination, err := arguments[2].ToString()
		if err != nil {
			return nil, err
		}
		if operation == "move" {
			return nil, os.Rename(path, destination)
		}
		return nil, copyFile(path, destination)
	}
	return nil, E.New("unknown file operation ", operation)
}
