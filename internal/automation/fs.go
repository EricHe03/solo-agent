//go:build darwin && cgo

package automation

import (
	"context"
	"os"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/jsc"
)

func (e *engine) fileRoot(kind string) (*fileRoot, error) {
	if kind == "cache" && e.caches != "" {
		if err := os.MkdirAll(e.caches, 0o755); err != nil {
			return nil, err
		}
		return openFileRoot(e.caches, "the cache directory")
	}
	return swipletRoot(e.swiplet, kind)
}

type fileLocation struct {
	root *fileRoot
	name string
}

func (c *operation) fileLocation(kind, name string) (*fileLocation, error) {
	cleaned, err := cleanName(name)
	if err != nil {
		return nil, err
	}
	root, err := c.engine.fileRoot(kind)
	if err != nil {
		return nil, err
	}
	return &fileLocation{root: root, name: cleaned}, nil
}

func (c *operation) oneFileLocation() (*fileLocation, error) {
	var kind, name string
	if err := c.decode(2, &kind, &name); err != nil {
		return nil, err
	}
	return c.fileLocation(kind, name)
}

type fileStat struct {
	Kind     string `json:"kind"`
	Size     int64  `json:"size"`
	Modified int64  `json:"modified"`
}

type fileEntry struct {
	Name      string `json:"name"`
	Directory bool   `json:"directory"`
}

func fsStat(_ context.Context, call *operation) (any, error) {
	at, err := call.oneFileLocation()
	if err != nil {
		return nil, err
	}
	defer at.root.Close()
	info, found, err := at.root.stat(at.name)
	if err != nil || !found {
		return nil, err
	}
	kind := "file"
	if info.Directory {
		kind = "directory"
	}
	return fileStat{Kind: kind, Size: info.Size, Modified: info.Modified.UnixMilli()}, nil
}

func fsList(_ context.Context, call *operation) (any, error) {
	at, err := call.oneFileLocation()
	if err != nil {
		return nil, err
	}
	defer at.root.Close()
	files, err := at.root.list(at.name)
	if err != nil {
		return nil, err
	}
	return common.Map(files, func(file FileInfo) fileEntry { return fileEntry{Name: file.Name, Directory: file.Directory} }), nil
}

func fsRead(_ context.Context, call *operation) (any, error) {
	at, err := call.oneFileLocation()
	if err != nil {
		return nil, err
	}
	defer at.root.Close()
	data, err := at.root.read(at.name)
	if err != nil {
		return nil, err
	}
	return jsc.Bytes(data), nil
}

func fsWrite(_ context.Context, call *operation) (any, error) {
	var kind, name, key string
	if err := call.decode(3, &kind, &name, &key); err != nil {
		return nil, err
	}
	at, err := call.fileLocation(kind, name)
	if err != nil {
		return nil, err
	}
	defer at.root.Close()
	data, err := call.engine.takeBlob(key)
	if err != nil {
		return nil, err
	}
	return nil, at.root.write(at.name, data)
}

func fsWriter(_ context.Context, call *operation) (any, error) {
	at, err := call.oneFileLocation()
	if err != nil {
		return nil, err
	}
	file, err := at.root.create(at.name)
	if err != nil {
		_ = at.root.Close()
		return nil, err
	}
	return call.engine.addResource(&resource{writer: file, finish: func(abort error) error {
		return E.Errors(file.finish(abort), at.root.Close())
	}}), nil
}

func fsMkdir(_ context.Context, call *operation) (any, error) {
	at, err := call.oneFileLocation()
	if err != nil {
		return nil, err
	}
	defer at.root.Close()
	return nil, at.root.mkdir(at.name)
}

func fsRemove(_ context.Context, call *operation) (any, error) {
	at, err := call.oneFileLocation()
	if err != nil {
		return nil, err
	}
	defer at.root.Close()
	return nil, at.root.remove(at.name)
}

func fsTransfer(move bool) operationFunc {
	return func(_ context.Context, call *operation) (any, error) {
		var fromKind, fromName, toKind, toName string
		if err := call.decode(4, &fromKind, &fromName, &toKind, &toName); err != nil {
			return nil, err
		}
		from, err := call.fileLocation(fromKind, fromName)
		if err != nil {
			return nil, err
		}
		defer from.root.Close()
		to, err := call.fileLocation(toKind, toName)
		if err != nil {
			return nil, err
		}
		defer to.root.Close()
		if move {
			return nil, from.root.moveTo(from.name, to.root, to.name)
		}
		return nil, from.root.copyTo(from.name, to.root, to.name)
	}
}
