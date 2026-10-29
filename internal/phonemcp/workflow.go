//go:build darwin && cgo

package phonemcp

import (
	_ "embed"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/jsc"
	"golang.org/x/sys/unix"
)

//go:embed workflow.js
var workflowSource string

const (
	SourceFolder = "src"
	DataFolder   = "data"
	EntryFile    = "main.js"
	lockFile     = ".lock"
)

var iconColors = []string{"red", "orange", "tangerine", "yellow", "lime", "teal", "cyan", "blue", "navy", "grape", "purple", "pink", "grayBlue", "grayGreen", "grayBrown"}

var DefaultIcon = Icon{Color: "grayBrown", Symbol: "square.2.layers.3d.fill"}

type Icon struct {
	Color  string `json:"color"`
	Symbol string `json:"symbol"`
}

func (i Icon) Check() error {
	if !slices.Contains(iconColors, i.Color) {
		return E.New("unknown color ", strconv.Quote(i.Color))
	}
	if i.Symbol == "" {
		return E.New("the symbol is empty")
	}
	return nil
}

func LoadIcon(directory string) Icon {
	source, err := os.ReadFile(filepath.Join(directory, SourceFolder, EntryFile))
	if err != nil {
		return DefaultIcon
	}
	return ReadHeader(string(source)).Icon
}

func SaveIcon(directory string, icon Icon) error {
	entry := filepath.Join(directory, SourceFolder, EntryFile)
	source, err := os.ReadFile(entry)
	if err != nil {
		return err
	}
	header := ReadHeader(string(source))
	header.Icon = icon
	return os.WriteFile(entry, []byte(WriteHeader(string(source), header)), 0o644)
}

func changeIcon(icon Icon, value jsc.Value) (Icon, error) {
	text, err := value.JSON()
	if err != nil {
		return icon, err
	}
	if err = json.Unmarshal([]byte(text), &icon); err != nil {
		return icon, E.Cause(err, "read the icon")
	}
	return icon, icon.Check()
}

func (s *Runner) workflowDirectory(name string) (string, error) {
	if name == "" || strings.HasPrefix(name, ".") || strings.ContainsAny(name, "/\x00") {
		return "", E.New("the workflow name ", strconv.Quote(name), " is empty, starts with a dot or has a slash")
	}
	return filepath.Join(s.workflows, name), nil
}

func (s *Runner) existingWorkflow(name string) (string, error) {
	directory, err := s.workflowDirectory(name)
	if err != nil {
		return "", err
	}
	if info, err := os.Stat(directory); err != nil || !info.IsDir() {
		return "", E.New("there is no workflow ", strconv.Quote(name))
	}
	return directory, nil
}

func (s *Runner) lockWorkflow(name string) (*os.File, error) {
	directory, err := s.existingWorkflow(name)
	if err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(directory, lockFile), os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return nil, E.Cause(err, "lock the workflow ", strconv.Quote(name))
	}
	err = unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB)
	if errors.Is(err, unix.EWOULDBLOCK) {
		file.Close()
		return nil, E.New("the workflow ", strconv.Quote(name), " is already running")
	}
	if err != nil {
		file.Close()
		return nil, E.Cause(err, "lock the workflow ", strconv.Quote(name))
	}
	return file, nil
}

func (s *Runner) runWorkflow(current *run, name string) {
	current.resident = true
	current.logger = s.logFactory.NewLogger("workflow/" + name)
	engine, err := s.newEngine(name, newElementTable())
	if err != nil {
		current.fail("start JavaScript: " + err.Error())
		return
	}
	defer engine.context.Close()
	engine.execute(current, func() (jsc.Value, error) { return engine.scope.Get("main") })
}

func texts(arguments []jsc.Value, count int) ([]string, error) {
	if len(arguments) < count {
		return nil, E.New("expected ", count, " arguments")
	}
	values := make([]string, count)
	for index := range values {
		value, err := arguments[index].ToString()
		if err != nil {
			return nil, err
		}
		values[index] = value
	}
	return values, nil
}

func fileName(text string) (string, error) {
	name := path.Clean(text)
	if !fs.ValidPath(name) || name == "." {
		return "", E.New("the path ", strconv.Quote(text), " leads out of the folder")
	}
	return name, nil
}

func (e *engine) openFolder(s *Runner, workflow, kind string, create bool) (*os.Root, error) {
	if e.workflow != "" && (workflow != e.workflow || kind != "data") {
		return nil, E.New("a workflow script reaches only its own data files")
	}
	directory, err := s.existingWorkflow(workflow)
	if err != nil {
		return nil, err
	}
	switch kind {
	case "source":
		directory = filepath.Join(directory, SourceFolder)
	case "data":
		directory = filepath.Join(directory, DataFolder)
	default:
		return nil, E.New("unknown folder ", strconv.Quote(kind))
	}
	if create {
		if err = os.MkdirAll(directory, 0o755); err != nil {
			return nil, err
		}
	}
	root, err := os.OpenRoot(directory)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	return root, err
}

func (e *engine) readFile(s *Runner, arguments []jsc.Value) ([]byte, error) {
	values, err := texts(arguments, 3)
	if err != nil {
		return nil, err
	}
	name, err := fileName(values[2])
	if err != nil {
		return nil, err
	}
	root, err := e.openFolder(s, values[0], values[1], false)
	if err != nil {
		return nil, err
	}
	if root == nil {
		return nil, E.New("there is no file ", name)
	}
	defer root.Close()
	data, err := root.ReadFile(name)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, E.New("there is no file ", name)
	}
	return data, err
}

func (e *engine) writeFile(s *Runner, arguments []jsc.Value, contents func(jsc.Value) ([]byte, error)) (any, error) {
	values, err := texts(arguments, 3)
	if err != nil {
		return nil, err
	}
	name, err := fileName(values[2])
	if err != nil {
		return nil, err
	}
	if len(arguments) < 4 {
		return nil, E.New("expected the contents")
	}
	data, err := contents(arguments[3])
	if err != nil {
		return nil, err
	}
	root, err := e.openFolder(s, values[0], values[1], true)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	if directory := path.Dir(name); directory != "." {
		if err = root.MkdirAll(directory, 0o755); err != nil {
			return nil, err
		}
	}
	return nil, root.WriteFile(name, data, 0o644)
}

func (e *engine) fileFunctions(s *Runner) map[string]jsc.Function {
	functions := map[string]jsc.Function{
		"list": func(arguments []jsc.Value) (any, error) {
			values, err := texts(arguments, 2)
			if err != nil {
				return nil, err
			}
			root, err := e.openFolder(s, values[0], values[1], false)
			if err != nil || root == nil {
				return []string{}, err
			}
			defer root.Close()
			files := []string{}
			err = fs.WalkDir(root.FS(), ".", func(name string, entry fs.DirEntry, err error) error {
				if err == nil && entry.Type().IsRegular() {
					files = append(files, name)
				}
				return err
			})
			return files, err
		},
		"exists": func(arguments []jsc.Value) (any, error) {
			values, err := texts(arguments, 3)
			if err != nil {
				return nil, err
			}
			name, err := fileName(values[2])
			if err != nil {
				return nil, err
			}
			root, err := e.openFolder(s, values[0], values[1], false)
			if err != nil || root == nil {
				return false, err
			}
			defer root.Close()
			info, err := root.Stat(name)
			return err == nil && info.Mode().IsRegular(), nil
		},
		"text": func(arguments []jsc.Value) (any, error) {
			data, err := e.readFile(s, arguments)
			if err != nil {
				return nil, err
			}
			return string(data), nil
		},
		"bytes": func(arguments []jsc.Value) (any, error) {
			data, err := e.readFile(s, arguments)
			if err != nil {
				return nil, err
			}
			return jsc.Bytes(data), nil
		},
		"writeText": func(arguments []jsc.Value) (any, error) {
			return e.writeFile(s, arguments, func(value jsc.Value) ([]byte, error) {
				text, err := value.ToString()
				return []byte(text), err
			})
		},
		"writeBytes": func(arguments []jsc.Value) (any, error) {
			return e.writeFile(s, arguments, func(value jsc.Value) ([]byte, error) {
				data, isBytes := value.Bytes()
				if !isBytes {
					return nil, E.New("the contents are not a Uint8Array")
				}
				return data, nil
			})
		},
		"remove": func(arguments []jsc.Value) (any, error) {
			values, err := texts(arguments, 3)
			if err != nil {
				return nil, err
			}
			name, err := fileName(values[2])
			if err != nil {
				return nil, err
			}
			root, err := e.openFolder(s, values[0], values[1], false)
			if err != nil || root == nil {
				return nil, err
			}
			defer root.Close()
			if err = root.Remove(name); errors.Is(err, fs.ErrNotExist) {
				return nil, nil
			}
			return nil, err
		},
	}
	if e.workflow == "" {
		functions["listWorkflows"] = func([]jsc.Value) (any, error) {
			entries, err := os.ReadDir(s.workflows)
			if errors.Is(err, fs.ErrNotExist) {
				return []string{}, nil
			}
			names := []string{}
			for _, entry := range entries {
				if entry.IsDir() && !strings.HasPrefix(entry.Name(), ".") {
					names = append(names, entry.Name())
				}
			}
			return names, err
		}
		functions["hasWorkflow"] = func(arguments []jsc.Value) (any, error) {
			values, err := texts(arguments, 1)
			if err != nil {
				return nil, err
			}
			directory, err := s.workflowDirectory(values[0])
			if err != nil {
				return nil, err
			}
			info, err := os.Stat(directory)
			return err == nil && info.IsDir(), nil
		}
		functions["createWorkflow"] = func(arguments []jsc.Value) (any, error) {
			values, err := texts(arguments, 2)
			if err != nil {
				return nil, err
			}
			directory, err := s.workflowDirectory(values[0])
			if err != nil {
				return nil, err
			}
			icon, err := changeIcon(LoadIcon(directory), arguments[1])
			if err != nil {
				return nil, err
			}
			if err = os.MkdirAll(s.workflows, 0o755); err != nil {
				return nil, err
			}
			if err = os.Mkdir(directory, 0o755); errors.Is(err, fs.ErrExist) {
				return nil, E.New("there is already a workflow ", strconv.Quote(values[0]))
			} else if err != nil {
				return nil, err
			}
			for _, folder := range []string{SourceFolder, DataFolder} {
				if err = os.Mkdir(filepath.Join(directory, folder), 0o755); err != nil {
					return nil, err
				}
			}
			var source string
			if icon != DefaultIcon {
				source = WriteHeader("", Header{Icon: icon})
			}
			return nil, os.WriteFile(filepath.Join(directory, SourceFolder, EntryFile), []byte(source), 0o644)
		}
		functions["icon"] = func(arguments []jsc.Value) (any, error) {
			values, err := texts(arguments, 1)
			if err != nil {
				return nil, err
			}
			directory, err := s.existingWorkflow(values[0])
			if err != nil {
				return nil, err
			}
			return LoadIcon(directory), nil
		}
		functions["setIcon"] = func(arguments []jsc.Value) (any, error) {
			values, err := texts(arguments, 2)
			if err != nil {
				return nil, err
			}
			directory, err := s.existingWorkflow(values[0])
			if err != nil {
				return nil, err
			}
			icon, err := changeIcon(LoadIcon(directory), arguments[1])
			if err != nil {
				return nil, err
			}
			return nil, SaveIcon(directory, icon)
		}
		functions["removeWorkflow"] = func(arguments []jsc.Value) (any, error) {
			values, err := texts(arguments, 1)
			if err != nil {
				return nil, err
			}
			directory, err := s.existingWorkflow(values[0])
			if err != nil {
				return nil, err
			}
			return nil, os.RemoveAll(directory)
		}
		functions["runWorkflow"] = func(arguments []jsc.Value) (any, error) {
			values, err := texts(arguments, 1)
			if err != nil {
				return nil, err
			}
			lock, err := s.lockWorkflow(values[0])
			if err != nil {
				return nil, err
			}
			defer lock.Close()
			current := e.run
			nested := &run{transcript: current.transcript, ctx: current.ctx, timeout: current.timeout, nested: true, dialog: current.dialog, stop: current.stop}
			s.runWorkflow(nested, values[0])
			if nested.failed {
				return nil, E.New("in workflow ", strconv.Quote(values[0]), ": ", strings.Join(nested.failures, "\n"))
			}
			if nested.value == "" {
				return nil, nil
			}
			return json.RawMessage(nested.value), nil
		}
		return functions
	}
	sources := func() (*os.Root, error) {
		directory, err := s.existingWorkflow(e.workflow)
		if err != nil {
			return nil, err
		}
		return os.OpenRoot(filepath.Join(directory, SourceFolder))
	}
	functions["resolve"] = func(arguments []jsc.Value) (any, error) {
		values, err := texts(arguments, 2)
		if err != nil {
			return nil, err
		}
		specifier, referrer := values[0], values[1]
		var name string
		switch {
		case strings.HasPrefix(specifier, "./"), strings.HasPrefix(specifier, "../"):
			name = path.Join(path.Dir(referrer), specifier)
		case strings.HasPrefix(specifier, "/"):
			name = path.Clean(specifier[1:])
		default:
			return nil, E.New("cannot import ", strconv.Quote(specifier), ": a specifier starts with ./, ../ or /")
		}
		if !fs.ValidPath(name) || name == "." {
			return nil, E.New("cannot import ", strconv.Quote(specifier), ": it leads out of the source files")
		}
		root, err := sources()
		if err != nil {
			return nil, E.Cause(err, "cannot import ", strconv.Quote(specifier))
		}
		defer root.Close()
		if info, err := root.Stat(name); err != nil || !info.Mode().IsRegular() {
			return nil, E.New("cannot import ", strconv.Quote(specifier), ": there is no source file ", name)
		}
		return name, nil
	}
	functions["source"] = func(arguments []jsc.Value) (any, error) {
		values, err := texts(arguments, 1)
		if err != nil {
			return nil, err
		}
		root, err := sources()
		if err != nil {
			return nil, err
		}
		defer root.Close()
		data, err := root.ReadFile(values[0])
		if err != nil {
			return nil, err
		}
		return string(data), nil
	}
	functions["evaluate"] = func(arguments []jsc.Value) (any, error) {
		values, err := texts(arguments, 2)
		if err != nil {
			return nil, err
		}
		return e.context.Evaluate(values[0], values[1])
	}
	return functions
}
