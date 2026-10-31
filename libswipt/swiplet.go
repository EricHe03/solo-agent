package libSwipt

import (
	"archive/zip"
	"bytes"
	"errors"
	"io"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"slices"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/automation"
	"golang.org/x/sys/unix"
)

var archiveMagic = []byte("PK\x03\x04")

type SwipletIcon struct {
	Color  string
	Symbol string
}

func LoadSwipletIcon(directory string) *SwipletIcon {
	icon := automation.LoadIcon(directory)
	return &SwipletIcon{Color: icon.Color, Symbol: icon.Symbol}
}

type SwipletManifest struct {
	ID        string
	Color     string
	Symbol    string
	Version   string
	UpdateURL string
	Service   bool
	languages []string
	names     []string
	actions   []automation.ActionInfo
}

func (m *SwipletManifest) Len() int32 { return int32(len(m.languages)) }

func (m *SwipletManifest) Language(index int32) string { return m.languages[index] }

func (m *SwipletManifest) Name(index int32) string { return m.names[index] }

func (m *SwipletManifest) ActionCount() int32 { return int32(len(m.actions)) }

func (m *SwipletManifest) ActionName(index int32) string { return m.actions[index].Name }

func (m *SwipletManifest) ActionTitle(index int32) string { return m.actions[index].Title }

func (m *SwipletManifest) ActionDescription(index int32) string { return m.actions[index].Description }

func (m *SwipletManifest) ActionExposed(index int32, caller string) bool {
	return slices.Contains(m.actions[index].Expose, automation.Caller(caller))
}

func newSwipletManifest(manifest automation.Manifest) *SwipletManifest {
	out := &SwipletManifest{
		ID: manifest.ID, Color: manifest.Icon.Color, Symbol: manifest.Icon.Symbol, Version: manifest.Version, UpdateURL: manifest.UpdateURL,
		Service: manifest.Service, languages: []string{""}, names: []string{manifest.Name}, actions: manifest.Actions,
	}
	for _, language := range slices.Sorted(maps.Keys(manifest.LocalizedNames)) {
		out.languages = append(out.languages, language)
		out.names = append(out.names, manifest.LocalizedNames[language])
	}
	return out
}

func ReadSwipletManifest(file string) (*SwipletManifest, error) {
	content, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	if !bytes.HasPrefix(content, archiveMagic) {
		return nil, E.New("the file is not a ZIP archive")
	}
	reader, err := zip.NewReader(bytes.NewReader(content), int64(len(content)))
	if err != nil {
		return nil, E.Cause(err, "open the archive")
	}
	archive, err := automation.ReadArchive(reader, "")
	if err != nil {
		return nil, err
	}
	return newSwipletManifest(archive.Manifest), nil
}

type SwipletInfo struct {
	ID        string
	Directory string
	Manifest  *SwipletManifest
}

type SwipletList struct {
	items []*SwipletInfo
}

func (l *SwipletList) Len() int32 { return int32(len(l.items)) }

func (l *SwipletList) Get(index int32) *SwipletInfo { return l.items[index] }

func (p *Platform) Swiplets() *SwipletList {
	list := &SwipletList{}
	for _, swiplet := range p.host.Swiplets() {
		list.items = append(list.items, &SwipletInfo{ID: swiplet.ID, Directory: swiplet.Directory, Manifest: newSwipletManifest(swiplet.Manifest)})
	}
	return list
}

func (p *Platform) InstallSwiplet(file string) (string, error) {
	archive, err := os.Open(file)
	if err != nil {
		return "", err
	}
	defer archive.Close()
	info, err := archive.Stat()
	if err != nil {
		return "", err
	}
	swiplet, err := p.host.Install(archive, info.Size())
	return swiplet.ID, err
}

func (p *Platform) RemoveSwiplet(swiplet string) error {
	return p.host.Remove(swiplet)
}

const etagAttribute = "io.nekohasekai.swipt.etag"

func (p *Platform) SwipletETag(swiplet string) string {
	installed, err := p.host.Swiplet(swiplet)
	if err != nil {
		return ""
	}
	manifest := filepath.Join(installed.Directory, automation.ManifestFile)
	size, err := unix.Getxattr(manifest, etagAttribute, nil)
	if err != nil || size <= 0 {
		return ""
	}
	value := make([]byte, size)
	size, err = unix.Getxattr(manifest, etagAttribute, value)
	if err != nil {
		return ""
	}
	return string(value[:size])
}

func (p *Platform) SetSwipletETag(swiplet string, etag string) error {
	installed, err := p.host.Swiplet(swiplet)
	if err != nil {
		return err
	}
	manifest := filepath.Join(installed.Directory, automation.ManifestFile)
	if etag == "" {
		err = unix.Removexattr(manifest, etagAttribute)
		if errors.Is(err, unix.ENOATTR) {
			return nil
		}
		return err
	}
	return unix.Setxattr(manifest, etagAttribute, []byte(etag), 0)
}

func (p *Platform) ExportSwiplet(swiplet string, destination string) error {
	installed, err := p.host.Swiplet(swiplet)
	if err != nil {
		return err
	}
	names := []string{automation.ManifestFile}
	if _, err = os.Stat(filepath.Join(installed.Directory, automation.IconFile)); err == nil {
		names = append(names, automation.IconFile)
	}
	err = fs.WalkDir(os.DirFS(installed.Directory), automation.SourceFolder, func(name string, item fs.DirEntry, err error) error {
		if err == nil && item.Type().IsRegular() {
			names = append(names, name)
		}
		return err
	})
	if err != nil {
		return err
	}
	file, err := os.Create(destination)
	if err != nil {
		return err
	}
	writer := zip.NewWriter(file)
	err = writeArchive(writer, installed.Directory, names)
	return E.Errors(err, writer.Close(), file.Close())
}

func writeArchive(writer *zip.Writer, directory string, names []string) error {
	for _, name := range names {
		info, err := os.Stat(filepath.Join(directory, name))
		if err != nil {
			return err
		}
		header, err := zip.FileInfoHeader(info)
		if err != nil {
			return err
		}
		header.Name, header.Method = name, zip.Deflate
		output, err := writer.CreateHeader(header)
		if err != nil {
			return err
		}
		if err = copyFile(output, filepath.Join(directory, name)); err != nil {
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

type SwipletFileInfo struct {
	Exists    bool
	Name      string
	Directory bool
	Size      int64
	Modified  int64
}

type SwipletFileList struct {
	items []*SwipletFileInfo
}

func (l *SwipletFileList) Len() int32 { return int32(len(l.items)) }

func (l *SwipletFileList) Get(index int32) *SwipletFileInfo { return l.items[index] }

func swipletFileInfo(info automation.FileInfo) *SwipletFileInfo {
	return &SwipletFileInfo{Exists: true, Name: info.Name, Directory: info.Directory, Size: info.Size, Modified: info.Modified.UnixMilli()}
}

func (p *Platform) StatSwipletFile(swiplet, path string) (*SwipletFileInfo, error) {
	info, found, err := p.host.StatFile(swiplet, path)
	if err != nil {
		return nil, err
	}
	if !found {
		return &SwipletFileInfo{}, nil
	}
	return swipletFileInfo(info), nil
}

func (p *Platform) ListSwipletFiles(swiplet, path string) (*SwipletFileList, error) {
	files, err := p.host.ListFiles(swiplet, path)
	if err != nil {
		return nil, err
	}
	return &SwipletFileList{items: common.Map(files, swipletFileInfo)}, nil
}

func (p *Platform) ReadSwipletFile(swiplet, path string) ([]byte, error) {
	data, err := p.host.ReadFile(swiplet, path)
	if err != nil {
		return nil, err
	}
	if data == nil {
		data = []byte{}
	}
	return data, nil
}

func (p *Platform) WriteSwipletFile(swiplet, path string, data []byte) error {
	return p.host.WriteFile(swiplet, path, data)
}

func (p *Platform) MakeSwipletDirectory(swiplet, path string) error {
	return p.host.MakeDirectory(swiplet, path)
}

func (p *Platform) RemoveSwipletFile(swiplet, path string) error {
	return p.host.RemoveFile(swiplet, path)
}

func (p *Platform) CopySwipletFile(swiplet, from, to string) error {
	return p.host.CopyFile(swiplet, from, to)
}

func (p *Platform) MoveSwipletFile(swiplet, from, to string) error {
	return p.host.MoveFile(swiplet, from, to)
}
