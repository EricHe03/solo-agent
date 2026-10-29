package libSwipt

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"maps"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/phonemcp"
	"golang.org/x/sys/unix"
)

func FormatJSON(content string) (string, error) {
	content = strings.TrimRight(content, " \t\r\n")
	var buffer bytes.Buffer
	err := json.Indent(&buffer, []byte(content), "", "  ")
	if syntaxError, isSyntaxError := errors.AsType[*json.SyntaxError](err); isSyntaxError {
		before := content[:syntaxError.Offset]
		line := strings.Count(before, "\n") + 1
		column := utf8.RuneCountInString(before[strings.LastIndexByte(before, '\n')+1:])
		return "", E.Extend(err, "line ", line, ", column ", column)
	}
	if err != nil {
		return "", err
	}
	buffer.WriteByte('\n')
	return buffer.String(), nil
}

type WorkflowIcon struct {
	Color  string
	Symbol string
}

func LoadWorkflowIcon(directory string) *WorkflowIcon {
	icon := phonemcp.LoadIcon(directory)
	return &WorkflowIcon{Color: icon.Color, Symbol: icon.Symbol}
}

func SaveWorkflowIcon(directory string, color string, symbol string) error {
	icon := phonemcp.Icon{Color: color, Symbol: symbol}
	if err := icon.Check(); err != nil {
		return err
	}
	return phonemcp.SaveIcon(directory, icon)
}

var archiveMagic = []byte("PK\x03\x04")

type archiveSource struct {
	file *zip.File
	name string
}

func readArchive(reader *zip.Reader, folder string) (entry []byte, sources []archiveSource, err error) {
	files := common.Filter(reader.File, func(file *zip.File) bool {
		return !file.FileInfo().IsDir() && !strings.HasPrefix(file.Name, "__MACOSX/") && path.Base(file.Name) != ".DS_Store"
	})
	var prefix string
	if len(files) > 0 {
		top, _, _ := strings.Cut(files[0].Name, "/")
		if common.All(files, func(file *zip.File) bool { return strings.HasPrefix(file.Name, top+"/") }) {
			prefix = top + "/"
		}
	}
	if folder != "" {
		prefix += folder + "/"
	}
	for _, file := range files {
		name, found := strings.CutPrefix(file.Name, prefix)
		if !found {
			continue
		}
		if !fs.ValidPath(name) || name == "." || strings.Contains(name, `\`) {
			return nil, nil, E.New("the archive has an unsafe path ", strconv.Quote(file.Name))
		}
		sources = append(sources, archiveSource{file, name})
	}
	index := slices.IndexFunc(sources, func(source archiveSource) bool { return source.name == phonemcp.EntryFile })
	if index < 0 {
		return nil, nil, E.New("the archive has no ", prefix+phonemcp.EntryFile)
	}
	entry, err = readZipFile(sources[index].file)
	return entry, sources, err
}

func readWorkflow(file string) (entry []byte, sources []archiveSource, err error) {
	content, err := os.ReadFile(file)
	if err != nil {
		return nil, nil, err
	}
	if !bytes.HasPrefix(content, archiveMagic) {
		if !utf8.Valid(content) {
			return nil, nil, E.New("the file is neither a script nor a ZIP archive")
		}
		return content, nil, nil
	}
	reader, err := zip.NewReader(bytes.NewReader(content), int64(len(content)))
	if err != nil {
		return nil, nil, E.Cause(err, "open the archive")
	}
	return readArchive(reader, "")
}

func readZipFile(file *zip.File) ([]byte, error) {
	reader, err := file.Open()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	return io.ReadAll(reader)
}

type WorkflowHeader struct {
	Color     string
	Symbol    string
	Version   string
	UpdateURL string
	languages []string
	names     []string
}

func (h *WorkflowHeader) Len() int32 { return int32(len(h.languages)) }

func (h *WorkflowHeader) Language(index int32) string { return h.languages[index] }

func (h *WorkflowHeader) Name(index int32) string { return h.names[index] }

func newWorkflowHeader(entry []byte) *WorkflowHeader {
	header := phonemcp.ReadHeader(string(entry))
	out := &WorkflowHeader{
		Color: header.Icon.Color, Symbol: header.Icon.Symbol, Version: header.Version, UpdateURL: header.UpdateURL,
		languages: []string{""}, names: []string{header.Name},
	}
	for _, language := range slices.Sorted(maps.Keys(header.Names)) {
		out.languages = append(out.languages, language)
		out.names = append(out.names, header.Names[language])
	}
	return out
}

func ReadWorkflowHeader(file string) (*WorkflowHeader, error) {
	entry, _, err := readWorkflow(file)
	if err != nil {
		return nil, err
	}
	return newWorkflowHeader(entry), nil
}

func LoadWorkflowHeader(directory string) (*WorkflowHeader, error) {
	entry, err := os.ReadFile(filepath.Join(directory, phonemcp.SourceFolder, phonemcp.EntryFile))
	if err != nil {
		return nil, err
	}
	return newWorkflowHeader(entry), nil
}

func ImportWorkflow(directory string, file string, updateURL string) (err error) {
	entry, sources, err := readWorkflow(file)
	if err != nil {
		return err
	}
	if header := phonemcp.ReadHeader(string(entry)); header.UpdateURL == "" && updateURL != "" {
		header.UpdateURL = updateURL
		entry = []byte(phonemcp.WriteHeader(string(entry), header))
	}
	if err = os.MkdirAll(filepath.Dir(directory), 0o755); err != nil {
		return err
	}
	if err = os.Mkdir(directory, 0o755); err != nil {
		return err
	}
	defer func() {
		if err != nil {
			os.RemoveAll(directory)
		}
	}()
	if err = os.Mkdir(filepath.Join(directory, phonemcp.DataFolder), 0o755); err != nil {
		return err
	}
	return writeSources(filepath.Join(directory, phonemcp.SourceFolder), entry, sources)
}

func UpdateWorkflow(directory string, file string) error {
	entry, sources, err := readWorkflow(file)
	if err != nil {
		return err
	}
	sourceFolder := filepath.Join(directory, phonemcp.SourceFolder)
	current, err := os.ReadFile(filepath.Join(sourceFolder, phonemcp.EntryFile))
	if err != nil {
		return err
	}
	local := phonemcp.ReadHeader(string(current))
	header := phonemcp.ReadHeader(string(entry))
	header.Icon = local.Icon
	if header.UpdateURL == "" {
		header.UpdateURL = local.UpdateURL
	}
	entry = []byte(phonemcp.WriteHeader(string(entry), header))
	staging := filepath.Join(directory, ".update")
	replaced := filepath.Join(directory, ".replaced")
	if err = E.Errors(os.RemoveAll(staging), os.RemoveAll(replaced)); err != nil {
		return err
	}
	if err = writeSources(staging, entry, sources); err != nil {
		return E.Append(err, os.RemoveAll(staging), func(err error) error { return E.Cause(err, "remove the staged sources") })
	}
	if err = os.Rename(sourceFolder, replaced); err != nil {
		return err
	}
	if err = os.Rename(staging, sourceFolder); err != nil {
		return E.Append(err, os.Rename(replaced, sourceFolder), func(err error) error { return E.Cause(err, "restore the sources") })
	}
	return os.RemoveAll(replaced)
}

func writeSources(folder string, entry []byte, sources []archiveSource) error {
	if err := os.Mkdir(folder, 0o755); err != nil {
		return err
	}
	root, err := os.OpenRoot(folder)
	if err != nil {
		return err
	}
	defer root.Close()
	for _, source := range sources {
		if source.name == phonemcp.EntryFile {
			continue
		}
		if err = extract(root, source.file, source.name); err != nil {
			return E.Cause(err, "extract ", source.file.Name)
		}
	}
	return root.WriteFile(phonemcp.EntryFile, entry, 0o644)
}

const etagAttribute = "io.nekohasekai.swipt.etag"

func WorkflowETag(directory string) string {
	entry := filepath.Join(directory, phonemcp.SourceFolder, phonemcp.EntryFile)
	size, err := unix.Getxattr(entry, etagAttribute, nil)
	if err != nil || size <= 0 {
		return ""
	}
	value := make([]byte, size)
	size, err = unix.Getxattr(entry, etagAttribute, value)
	if err != nil {
		return ""
	}
	return string(value[:size])
}

func SetWorkflowETag(directory string, etag string) error {
	entry := filepath.Join(directory, phonemcp.SourceFolder, phonemcp.EntryFile)
	if etag == "" {
		err := unix.Removexattr(entry, etagAttribute)
		if errors.Is(err, unix.ENOATTR) {
			return nil
		}
		return err
	}
	return unix.Setxattr(entry, etagAttribute, []byte(etag), 0)
}

func extract(root *os.Root, file *zip.File, name string) error {
	if folder := path.Dir(name); folder != "." {
		if err := root.MkdirAll(folder, 0o755); err != nil {
			return err
		}
	}
	reader, err := file.Open()
	if err != nil {
		return err
	}
	defer reader.Close()
	writer, err := root.Create(name)
	if err != nil {
		return err
	}
	_, err = io.Copy(writer, reader)
	return E.Errors(err, writer.Close())
}

func sourceNames(directory string) ([]string, error) {
	var names []string
	err := fs.WalkDir(os.DirFS(filepath.Join(directory, phonemcp.SourceFolder)), ".", func(name string, item fs.DirEntry, err error) error {
		if err == nil && item.Type().IsRegular() {
			names = append(names, name)
		}
		return err
	})
	return names, err
}

func IsSingleFileWorkflow(directory string) bool {
	names, err := sourceNames(directory)
	return err == nil && slices.Equal(names, []string{phonemcp.EntryFile})
}

func ExportWorkflow(directory string, destination string, keepNames bool) error {
	names, err := sourceNames(directory)
	if err != nil {
		return err
	}
	sources := filepath.Join(directory, phonemcp.SourceFolder)
	entry, err := os.ReadFile(filepath.Join(sources, phonemcp.EntryFile))
	if err != nil {
		return err
	}
	header := phonemcp.ReadHeader(string(entry))
	if !keepNames {
		header.Name, header.Names = filepath.Base(directory), nil
	}
	entry = []byte(phonemcp.WriteHeader(string(entry), header))
	if slices.Equal(names, []string{phonemcp.EntryFile}) {
		return os.WriteFile(destination, entry, 0o644)
	}
	file, err := os.Create(destination)
	if err != nil {
		return err
	}
	writer := zip.NewWriter(file)
	err = writeArchive(writer, sources, names, entry)
	return E.Errors(err, writer.Close(), file.Close())
}

func writeArchive(writer *zip.Writer, directory string, names []string, entry []byte) error {
	for _, name := range names {
		info, err := os.Stat(filepath.Join(directory, name))
		if err != nil {
			return err
		}
		header, err := zip.FileInfoHeader(info)
		if err != nil {
			return err
		}
		header.Name = name
		header.Method = zip.Deflate
		output, err := writer.CreateHeader(header)
		if err != nil {
			return err
		}
		if name == phonemcp.EntryFile {
			_, err = output.Write(entry)
		} else {
			err = copyFile(output, filepath.Join(directory, name))
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func copyFile(writer io.Writer, name string) error {
	file, err := os.Open(name)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = io.Copy(writer, file)
	return err
}
