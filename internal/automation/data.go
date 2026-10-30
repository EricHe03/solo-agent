//go:build darwin && cgo

package automation

import (
	"crypto/rand"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

type FileInfo struct {
	Name      string
	Directory bool
	Size      int64
	Modified  time.Time
}

func FileNotFound(id, name string) error {
	return E.Cause1(ErrNotFound, E.New("there is no ", strconv.Quote(filepath.ToSlash(name)), " in the data directory of ", id))
}

func dataError(id, name string, err error) error {
	pathError, isPath := errors.AsType[*fs.PathError](err)
	if !isPath {
		return err
	}
	shown := strconv.Quote(filepath.ToSlash(name))
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return FileNotFound(id, name)
	case errors.Is(err, syscall.ENOTDIR):
		return E.Cause1(ErrInvalid, E.New("a file stands where ", shown, " needs a directory in the data directory of ", id))
	case errors.Is(err, syscall.EISDIR):
		return E.Cause1(ErrInvalid, E.New(shown, " is a directory in the data directory of ", id))
	}
	return E.New(shown, " in the data directory of ", id, ": ", pathError.Err)
}

func (h *Host) dataRoot(id string) (*os.Root, error) {
	swiplet, err := h.Swiplet(id)
	if err != nil {
		return nil, err
	}
	directory := filepath.Join(swiplet.Directory, DataFolder)
	if err = os.MkdirAll(directory, 0o755); err != nil {
		return nil, err
	}
	return os.OpenRoot(directory)
}

func (h *Host) ListFiles(id, name string) ([]FileInfo, error) {
	root, err := h.dataRoot(id)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	directory, err := root.Open(filepath.Clean(filepath.FromSlash(name)))
	if err != nil {
		return nil, dataError(id, name, err)
	}
	defer directory.Close()
	entries, err := directory.ReadDir(-1)
	if err != nil {
		return nil, dataError(id, name, err)
	}
	files := make([]FileInfo, 0, len(entries))
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			return nil, err
		}
		files = append(files, FileInfo{Name: entry.Name(), Directory: entry.IsDir(), Size: info.Size(), Modified: info.ModTime()})
	}
	return files, nil
}

func (h *Host) ReadFile(id, name string) ([]byte, error) {
	root, err := h.dataRoot(id)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	data, err := root.ReadFile(filepath.FromSlash(name))
	if err != nil {
		return nil, dataError(id, name, err)
	}
	return data, nil
}

func (h *Host) WriteFile(id, name string, data []byte) error {
	name = filepath.Clean(filepath.FromSlash(name))
	if name == "." {
		return E.Cause1(ErrInvalid, E.New("the path names the data directory"))
	}
	root, err := h.dataRoot(id)
	if err != nil {
		return err
	}
	defer root.Close()
	if err = root.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		return dataError(id, filepath.Dir(name), err)
	}
	temporary := filepath.Join(filepath.Dir(name), ".write-"+rand.Text())
	file, err := root.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	_, err = file.Write(data)
	err = E.Errors(err, file.Close())
	if err == nil {
		err = root.Rename(temporary, name)
	}
	if err != nil {
		_ = root.Remove(temporary)
		return dataError(id, name, err)
	}
	return nil
}

func (h *Host) RemoveFile(id, name string) error {
	name = filepath.Clean(filepath.FromSlash(name))
	if name == "." {
		return E.Cause1(ErrInvalid, E.New("the path names the data directory"))
	}
	root, err := h.dataRoot(id)
	if err != nil {
		return err
	}
	defer root.Close()
	if err = root.RemoveAll(name); err != nil {
		return dataError(id, name, err)
	}
	return nil
}
