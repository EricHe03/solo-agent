//go:build darwin && cgo

package automation

import (
	"crypto/rand"
	"errors"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
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

type fileRoot struct {
	root  *os.Root
	where string
}

func openFileRoot(directory, where string) (*fileRoot, error) {
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return nil, err
	}
	root, err := os.OpenRoot(directory)
	if err != nil {
		return nil, err
	}
	return &fileRoot{root: root, where: where}, nil
}

func (r *fileRoot) Close() error {
	return r.root.Close()
}

func cleanName(name string) (string, error) {
	if strings.HasPrefix(name, "/") {
		return "", E.Cause1(ErrInvalid, E.New("the path ", strconv.Quote(name), " is absolute"))
	}
	cleaned := path.Clean(name)
	if cleaned == "." || cleaned == "" {
		return ".", nil
	}
	if !fs.ValidPath(cleaned) {
		return "", E.Cause1(ErrInvalid, E.New("the path ", strconv.Quote(name), " leaves the directory"))
	}
	return filepath.FromSlash(cleaned), nil
}

func FileNotFound(where, name string) error {
	return E.Cause1(ErrNotFound, E.New("there is no ", strconv.Quote(filepath.ToSlash(name)), " in ", where))
}

func (r *fileRoot) error(name string, err error) error {
	pathError, isPath := errors.AsType[*fs.PathError](err)
	if !isPath {
		return err
	}
	shown := strconv.Quote(filepath.ToSlash(name))
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return FileNotFound(r.where, name)
	case errors.Is(err, syscall.ENOTDIR):
		return E.Cause1(ErrInvalid, E.New("a file stands where ", shown, " needs a directory in ", r.where))
	case errors.Is(err, syscall.EISDIR):
		return E.Cause1(ErrInvalid, E.New(shown, " is a directory in ", r.where))
	case errors.Is(err, syscall.ENOTEMPTY), errors.Is(err, syscall.EEXIST):
		return E.Cause1(ErrInvalid, E.New(shown, " already exists in ", r.where))
	}
	return E.New(shown, " in ", r.where, ": ", pathError.Err)
}

func (r *fileRoot) notRoot(name string) error {
	if name == "." {
		return E.Cause1(ErrInvalid, E.New("the path names ", r.where, " itself"))
	}
	return nil
}

func (r *fileRoot) stat(name string) (FileInfo, bool, error) {
	info, err := r.root.Stat(name)
	if errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ENOTDIR) {
		return FileInfo{}, false, nil
	}
	if err != nil {
		return FileInfo{}, false, r.error(name, err)
	}
	return FileInfo{Name: info.Name(), Directory: info.IsDir(), Size: info.Size(), Modified: info.ModTime()}, true, nil
}

func (r *fileRoot) list(name string) ([]FileInfo, error) {
	directory, err := r.root.Open(name)
	if err != nil {
		return nil, r.error(name, err)
	}
	defer directory.Close()
	entries, err := directory.ReadDir(-1)
	if err != nil {
		return nil, r.error(name, err)
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

func (r *fileRoot) read(name string) ([]byte, error) {
	data, err := r.root.ReadFile(name)
	if err != nil {
		return nil, r.error(name, err)
	}
	return data, nil
}

func (r *fileRoot) write(name string, data []byte) error {
	if err := r.notRoot(name); err != nil {
		return err
	}
	if err := r.root.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		return r.error(filepath.Dir(name), err)
	}
	temporary := filepath.Join(filepath.Dir(name), ".write-"+rand.Text())
	file, err := r.root.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	_, err = file.Write(data)
	err = E.Errors(err, file.Close())
	if err == nil {
		err = r.root.Rename(temporary, name)
	}
	if err != nil {
		_ = r.root.Remove(temporary)
		return r.error(name, err)
	}
	return nil
}

func (r *fileRoot) mkdir(name string) error {
	if err := r.root.MkdirAll(name, 0o755); err != nil {
		return r.error(name, err)
	}
	return nil
}

func (r *fileRoot) remove(name string) error {
	if err := r.notRoot(name); err != nil {
		return err
	}
	if err := r.root.RemoveAll(name); err != nil {
		return r.error(name, err)
	}
	return nil
}

func (r *fileRoot) copyTo(name string, destination *fileRoot, target string) error {
	if err := destination.notRoot(target); err != nil {
		return err
	}
	return fs.WalkDir(r.root.FS(), filepath.ToSlash(name), func(current string, entry fs.DirEntry, err error) error {
		if err != nil {
			return r.error(current, err)
		}
		relative, err := filepath.Rel(name, filepath.FromSlash(current))
		if err != nil {
			return err
		}
		to := filepath.Join(target, relative)
		if entry.IsDir() {
			return destination.mkdir(to)
		}
		in, err := r.root.Open(filepath.FromSlash(current))
		if err != nil {
			return r.error(current, err)
		}
		defer in.Close()
		if err = destination.root.MkdirAll(filepath.Dir(to), 0o755); err != nil {
			return destination.error(filepath.Dir(to), err)
		}
		out, err := destination.root.Create(to)
		if err != nil {
			return destination.error(to, err)
		}
		_, err = io.Copy(out, in)
		return E.Errors(err, out.Close())
	})
}

func (r *fileRoot) moveTo(name string, destination *fileRoot, target string) error {
	if err := E.Errors(r.notRoot(name), destination.notRoot(target)); err != nil {
		return err
	}
	if r.root.Name() == destination.root.Name() {
		if err := destination.root.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return destination.error(filepath.Dir(target), err)
		}
		if err := r.root.Rename(name, target); err != nil {
			return r.error(name, err)
		}
		return nil
	}
	if err := r.copyTo(name, destination, target); err != nil {
		return err
	}
	return r.remove(name)
}

func (h *Host) dataRoot(id string) (*fileRoot, error) {
	swiplet, err := h.Swiplet(id)
	if err != nil {
		return nil, err
	}
	return openFileRoot(filepath.Join(swiplet.Directory, DataFolder), "the data directory of "+id)
}

func (h *Host) withData(id, name string, work func(root *fileRoot, name string) error) error {
	name, err := cleanName(name)
	if err != nil {
		return err
	}
	root, err := h.dataRoot(id)
	if err != nil {
		return err
	}
	defer root.Close()
	return work(root, name)
}

func (h *Host) StatFile(id, name string) (info FileInfo, found bool, err error) {
	err = h.withData(id, name, func(root *fileRoot, name string) error {
		info, found, err = root.stat(name)
		return err
	})
	return
}

func (h *Host) ListFiles(id, name string) (files []FileInfo, err error) {
	err = h.withData(id, name, func(root *fileRoot, name string) error {
		files, err = root.list(name)
		return err
	})
	return
}

func (h *Host) ReadFile(id, name string) (data []byte, err error) {
	err = h.withData(id, name, func(root *fileRoot, name string) error {
		data, err = root.read(name)
		return err
	})
	return
}

func (h *Host) WriteFile(id, name string, data []byte) error {
	return h.withData(id, name, func(root *fileRoot, name string) error { return root.write(name, data) })
}

func (h *Host) MakeDirectory(id, name string) error {
	return h.withData(id, name, func(root *fileRoot, name string) error { return root.mkdir(name) })
}

func (h *Host) RemoveFile(id, name string) error {
	return h.withData(id, name, func(root *fileRoot, name string) error { return root.remove(name) })
}

func (h *Host) CopyFile(id, name, target string) error {
	target, err := cleanName(target)
	if err != nil {
		return err
	}
	return h.withData(id, name, func(root *fileRoot, name string) error { return root.copyTo(name, root, target) })
}

func (h *Host) MoveFile(id, name, target string) error {
	target, err := cleanName(target)
	if err != nil {
		return err
	}
	return h.withData(id, name, func(root *fileRoot, name string) error { return root.moveTo(name, root, target) })
}
