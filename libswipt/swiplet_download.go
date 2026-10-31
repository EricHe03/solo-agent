package libSwipt

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/automation"
)

const (
	swipletHeadSize    = 64 << 10
	sourceLimit        = 4 << 20
	swipletIdleTimeout = 15 * time.Second
	remoteWindowSize   = 64 << 10
	remoteWindowLimit  = 4 << 20
	localFileSignature = 0x04034b50
)

var swipletClient = func() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.DialContext = func(ctx context.Context, network string, address string) (net.Conn, error) {
		conn, err := (&net.Dialer{Timeout: swipletIdleTimeout}).DialContext(ctx, network, address)
		if err != nil {
			return nil, err
		}
		return &idleConn{conn}, nil
	}
	transport.TLSHandshakeTimeout = swipletIdleTimeout
	return &http.Client{Transport: transport}
}()

type idleConn struct {
	net.Conn
}

func (c *idleConn) Read(p []byte) (int, error) {
	if err := c.SetReadDeadline(time.Now().Add(swipletIdleTimeout)); err != nil {
		return 0, err
	}
	return c.Conn.Read(p)
}

func (c *idleConn) Write(p []byte) (int, error) {
	if err := c.SetWriteDeadline(time.Now().Add(swipletIdleTimeout)); err != nil {
		return 0, err
	}
	return c.Conn.Write(p)
}

type SwipletDownload struct {
	URL         string
	EntityTag   string
	Name        string
	ID          string
	Version     string
	VersionCode int64

	ErrorCode    int32
	ErrorMessage string
}

const (
	SwipletErrorNone    int32 = 0
	SwipletErrorFailed  int32 = 1
	SwipletErrorTimeout int32 = 2
)

type SwipletDownloader struct {
	ctx    context.Context
	cancel context.CancelFunc
}

func NewSwipletDownloader() *SwipletDownloader {
	ctx, cancel := context.WithCancel(context.Background())
	return &SwipletDownloader{ctx: ctx, cancel: cancel}
}

func (d *SwipletDownloader) Cancel() {
	d.cancel()
}

func (d *SwipletDownloader) Download(link string, destination string, etag string, version string, versionCode int64, id string) *SwipletDownload {
	download, err := d.download(link, destination, etag, version, versionCode, id)
	switch {
	case err == nil:
		return download
	case E.IsTimeout(err):
		return &SwipletDownload{ErrorCode: SwipletErrorTimeout, ErrorMessage: err.Error()}
	default:
		return &SwipletDownload{ErrorCode: SwipletErrorFailed, ErrorMessage: err.Error()}
	}
}

func (d *SwipletDownloader) download(link string, destination string, etag string, version string, versionCode int64, id string) (*SwipletDownload, error) {
	location, folder, _ := strings.Cut(link, "!/")
	if unescaped, err := url.PathUnescape(folder); err == nil {
		folder = unescaped
	}
	folder = strings.Trim(folder, "/")
	target, err := url.Parse(location)
	if err != nil {
		return nil, err
	}
	if target.Scheme != "http" && target.Scheme != "https" {
		return nil, E.New("unsupported URL ", strconv.Quote(link))
	}
	request, err := http.NewRequestWithContext(d.ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Range", "bytes=0-"+strconv.Itoa(swipletHeadSize-1))
	if etag != "" {
		request.Header.Set("If-None-Match", etag)
	}
	response, err := swipletClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	download := &SwipletDownload{URL: response.Request.URL.String(), EntityTag: response.Header.Get("ETag")}
	switch response.StatusCode {
	case http.StatusNotModified:
		return download, nil
	case http.StatusOK, http.StatusPartialContent:
	default:
		return nil, E.New(response.Status)
	}
	name := folder
	if name == "" {
		name = response.Request.URL.Path
		if _, params, err := mime.ParseMediaType(response.Header.Get("Content-Disposition")); err == nil && params["filename"] != "" {
			name = params["filename"]
		}
	}
	name = path.Base(name)
	download.Name = strings.TrimSuffix(name, path.Ext(name))
	head, err := io.ReadAll(io.LimitReader(response.Body, swipletHeadSize))
	if err != nil {
		return nil, err
	}
	if !bytes.HasPrefix(head, archiveMagic) {
		if bytes.HasPrefix(bytes.TrimLeft(head, " \t\r\n"), []byte("{")) {
			return d.fromSource(download, response, head, destination, version, versionCode, id, link)
		}
		return nil, E.New("the file is neither a swiplet nor a source")
	}
	var remote *remoteFile
	content := io.MultiReader(bytes.NewReader(head), response.Body)
	if response.StatusCode == http.StatusPartialContent {
		if remote, err = newRemoteFile(d.ctx, response, head); err != nil {
			return nil, err
		}
		content = io.NewSectionReader(remote, 0, remote.size)
	}
	var archive io.ReaderAt
	var size int64
	if remote != nil {
		archive, size = remote, remote.size
	} else {
		file, err := os.Create(destination + ".download")
		if err != nil {
			return nil, err
		}
		defer os.Remove(file.Name())
		defer file.Close()
		if folder != "" && response.Request.URL.Host == "codeload.github.com" {
			writer := zip.NewWriter(file)
			err = E.Errors(copyArchiveFolder(writer, content, folder), writer.Close())
		} else {
			_, err = io.Copy(file, content)
		}
		if err != nil {
			return nil, err
		}
		if size, err = file.Seek(0, io.SeekCurrent); err != nil {
			return nil, err
		}
		archive = file
	}
	return finish(download, archive, size, folder, link, false, destination, version, versionCode)
}

type FetchResult struct {
	EntityTag   string
	NotModified bool
	Data        []byte

	ErrorCode    int32
	ErrorMessage string
}

func (d *SwipletDownloader) Fetch(link string, etag string, asSource bool) *FetchResult {
	fetched, err := d.fetch(link, etag, asSource)
	switch {
	case err == nil:
		return fetched
	case E.IsTimeout(err):
		return &FetchResult{ErrorCode: SwipletErrorTimeout, ErrorMessage: err.Error()}
	default:
		return &FetchResult{ErrorCode: SwipletErrorFailed, ErrorMessage: err.Error()}
	}
}

func (d *SwipletDownloader) fetch(link string, etag string, asSource bool) (*FetchResult, error) {
	target, err := url.Parse(link)
	if err != nil {
		return nil, err
	}
	if target.Scheme != "http" && target.Scheme != "https" {
		return nil, E.New("unsupported URL ", strconv.Quote(link))
	}
	request, err := http.NewRequestWithContext(d.ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return nil, err
	}
	if etag != "" {
		request.Header.Set("If-None-Match", etag)
	}
	response, err := swipletClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	fetched := &FetchResult{EntityTag: response.Header.Get("ETag")}
	switch response.StatusCode {
	case http.StatusNotModified:
		fetched.NotModified = true
		return fetched, nil
	case http.StatusOK:
	default:
		return nil, E.New(response.Status)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, sourceLimit+1))
	if err != nil {
		return nil, err
	}
	if len(data) > sourceLimit {
		return nil, E.New("the file is larger than ", sourceLimit>>20, " MB")
	}
	if asSource {
		var listed source
		if err = json.Unmarshal(data, &listed); err != nil {
			return nil, E.Cause(err, "read the source")
		}
		if listed.Swiplets == nil {
			return nil, E.New("the file is not a source")
		}
	}
	fetched.Data = data
	return fetched, nil
}

type sourceEntry struct {
	ID          string `json:"id"`
	Version     string `json:"version"`
	VersionCode int64  `json:"versionCode"`
	URL         string `json:"url"`
	SHA256      string `json:"sha256"`
}

type source struct {
	Swiplets []sourceEntry `json:"swiplets"`
}

func (d *SwipletDownloader) get(location string) (*http.Response, error) {
	request, err := http.NewRequestWithContext(d.ctx, http.MethodGet, location, nil)
	if err != nil {
		return nil, err
	}
	response, err := swipletClient.Do(request)
	if err != nil {
		return nil, err
	}
	if response.StatusCode != http.StatusOK {
		response.Body.Close()
		return nil, E.New(response.Status)
	}
	return response, nil
}

func (d *SwipletDownloader) fromSource(download *SwipletDownload, response *http.Response, head []byte, destination string, version string, versionCode int64, id string, link string) (*SwipletDownload, error) {
	var body io.Reader = io.MultiReader(bytes.NewReader(head), response.Body)
	if response.StatusCode == http.StatusPartialContent {
		full, err := d.get(response.Request.URL.String())
		if err != nil {
			return nil, err
		}
		defer full.Body.Close()
		body = full.Body
	}
	data, err := io.ReadAll(io.LimitReader(body, sourceLimit+1))
	if err != nil {
		return nil, err
	}
	if len(data) > sourceLimit {
		return nil, E.New("the source is larger than ", sourceLimit>>20, " MB")
	}
	var listed source
	if err = json.Unmarshal(data, &listed); err != nil {
		return nil, E.Cause(err, "read the source")
	}
	var entry sourceEntry
	switch {
	case id != "":
		entry = common.Find(listed.Swiplets, func(it sourceEntry) bool { return it.ID == id })
		if entry.ID == "" {
			return nil, E.New("the source no longer lists ", strconv.Quote(id))
		}
	case len(listed.Swiplets) == 1:
		entry = listed.Swiplets[0]
	case len(listed.Swiplets) == 0:
		return nil, E.New("the source lists no swiplets")
	default:
		return nil, E.New("the source lists ", len(listed.Swiplets), " swiplets; import one of them by its own URL")
	}
	download.ID, download.Version, download.VersionCode = entry.ID, entry.Version, entry.VersionCode
	if (version != "" || versionCode > 0) && !automation.IsNewer(automation.Manifest{Version: entry.Version, VersionCode: entry.VersionCode}, version, versionCode) {
		return download, nil
	}
	target, err := url.Parse(entry.URL)
	if err != nil {
		return nil, E.Cause(err, "read the URL of ", entry.ID)
	}
	target = response.Request.URL.ResolveReference(target)
	if target.Scheme != "http" && target.Scheme != "https" {
		return nil, E.New("unsupported URL ", strconv.Quote(target.String()))
	}
	download.Name = strings.TrimSuffix(path.Base(target.Path), path.Ext(target.Path))
	archive, err := d.get(target.String())
	if err != nil {
		return nil, err
	}
	defer archive.Body.Close()
	file, err := os.Create(destination + ".download")
	if err != nil {
		return nil, err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	hash := sha256.New()
	size, err := io.Copy(io.MultiWriter(file, hash), archive.Body)
	if err != nil {
		return nil, err
	}
	if entry.SHA256 != "" && !strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), entry.SHA256) {
		return nil, E.New("the download of ", entry.ID, " doesn't match the checksum in the source")
	}
	finished, err := finish(download, file, size, "", link, true, destination, version, versionCode)
	if err != nil {
		return nil, err
	}
	if finished.ID != entry.ID {
		return nil, E.New("the source points ", strconv.Quote(entry.ID), " at the swiplet ", strconv.Quote(finished.ID))
	}
	return finished, nil
}

func finish(download *SwipletDownload, archive io.ReaderAt, size int64, folder string, link string, fromSource bool, destination string, version string, versionCode int64) (*SwipletDownload, error) {
	reader, err := zip.NewReader(archive, size)
	if err != nil {
		return nil, E.Cause(err, "open the archive")
	}
	contents, err := automation.ReadArchive(reader, folder)
	if err != nil {
		return nil, err
	}
	download.ID, download.Version, download.VersionCode = contents.Manifest.ID, contents.Manifest.Version, contents.Manifest.VersionCode
	if (version != "" || versionCode > 0) && !automation.IsNewer(contents.Manifest, version, versionCode) {
		return download, nil
	}
	file, err := os.Create(destination)
	if err != nil {
		return nil, err
	}
	writer := zip.NewWriter(file)
	err = copyArchive(writer, contents, link, fromSource)
	if err = E.Errors(err, writer.Close(), file.Close()); err != nil {
		return nil, err
	}
	return download, nil
}

func copyArchive(writer *zip.Writer, contents automation.Archive, link string, fromSource bool) error {
	for _, source := range contents.Files {
		if source.Name == automation.ManifestFile && (fromSource || contents.Manifest.UpdateURL == "") {
			manifest := contents.Manifest
			manifest.UpdateURL = link
			data, err := automation.EncodeManifest(manifest)
			if err != nil {
				return err
			}
			output, err := writer.CreateHeader(&zip.FileHeader{Name: source.Name, Method: zip.Deflate, Modified: source.Modified})
			if err != nil {
				return err
			}
			if _, err = output.Write(data); err != nil {
				return err
			}
			continue
		}
		header := source.FileHeader
		header.Name, header.Extra = source.Name, nil
		output, err := writer.CreateRaw(&header)
		if err != nil {
			return err
		}
		input, err := source.OpenRaw()
		if err != nil {
			return err
		}
		if _, err = io.Copy(output, input); err != nil {
			return err
		}
	}
	return nil
}

func copyArchiveFolder(writer *zip.Writer, reader io.Reader, folder string) error {
	var prefix string
	var entered bool
	for {
		var header [30]byte
		if _, err := io.ReadFull(reader, header[:]); err != nil {
			return err
		}
		if binary.LittleEndian.Uint32(header[0:]) != localFileSignature {
			return nil
		}
		file := &zip.FileHeader{
			Flags:              binary.LittleEndian.Uint16(header[6:]),
			Method:             binary.LittleEndian.Uint16(header[8:]),
			CRC32:              binary.LittleEndian.Uint32(header[14:]),
			CompressedSize64:   uint64(binary.LittleEndian.Uint32(header[18:])),
			UncompressedSize64: uint64(binary.LittleEndian.Uint32(header[22:])),
		}
		if file.Flags&0x8 != 0 || file.CompressedSize64 == 0xffffffff {
			return E.New("the archive can't be read as a stream")
		}
		name := make([]byte, binary.LittleEndian.Uint16(header[26:]))
		if _, err := io.ReadFull(reader, name); err != nil {
			return err
		}
		if _, err := io.CopyN(io.Discard, reader, int64(binary.LittleEndian.Uint16(header[28:]))); err != nil {
			return err
		}
		file.Name = string(name)
		if prefix == "" {
			top, _, _ := strings.Cut(file.Name, "/")
			prefix = top + "/" + folder + "/"
		}
		var output io.Writer = io.Discard
		if strings.HasPrefix(file.Name, prefix) {
			entered = true
			var err error
			if output, err = writer.CreateRaw(file); err != nil {
				return err
			}
		} else if entered {
			return nil
		}
		if _, err := io.CopyN(output, reader, int64(file.CompressedSize64)); err != nil {
			return err
		}
	}
}

type remoteFile struct {
	ctx       context.Context
	url       string
	validator string
	size      int64
	start     int64
	window    []byte
}

func newRemoteFile(ctx context.Context, response *http.Response, head []byte) (*remoteFile, error) {
	contentRange := response.Header.Get("Content-Range")
	var first, last, size int64
	if _, err := fmt.Sscanf(contentRange, "bytes %d-%d/%d", &first, &last, &size); err != nil || first != 0 || last+1 != int64(len(head)) {
		return nil, E.New("unexpected Content-Range ", strconv.Quote(contentRange))
	}
	validator := response.Header.Get("ETag")
	if validator == "" || strings.HasPrefix(validator, "W/") {
		validator = response.Header.Get("Last-Modified")
	}
	return &remoteFile{ctx: ctx, url: response.Request.URL.String(), validator: validator, size: size, window: head}, nil
}

func (f *remoteFile) ReadAt(p []byte, offset int64) (int, error) {
	if offset >= f.size {
		return 0, io.EOF
	}
	end := min(offset+int64(len(p)), f.size)
	if windowEnd := f.start + int64(len(f.window)); offset < f.start || end > windowEnd {
		size := int64(remoteWindowSize)
		if offset >= f.start && offset <= windowEnd {
			size = min(max(2*int64(len(f.window)), size), remoteWindowLimit)
		}
		if err := f.fetch(offset, min(max(end, offset+size), f.size)); err != nil {
			return 0, err
		}
	}
	n := copy(p, f.window[offset-f.start:])
	if n < len(p) {
		return n, io.EOF
	}
	return n, nil
}

func (f *remoteFile) fetch(start int64, end int64) error {
	request, err := http.NewRequestWithContext(f.ctx, http.MethodGet, f.url, nil)
	if err != nil {
		return err
	}
	request.Header.Set("Range", "bytes="+strconv.FormatInt(start, 10)+"-"+strconv.FormatInt(end-1, 10))
	if f.validator != "" {
		request.Header.Set("If-Range", f.validator)
	}
	response, err := swipletClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	switch {
	case response.StatusCode == http.StatusOK:
		return E.New("the file changed during the download")
	case response.StatusCode != http.StatusPartialContent:
		return E.New(response.Status)
	case !strings.HasPrefix(response.Header.Get("Content-Range"), "bytes "+strconv.FormatInt(start, 10)+"-"):
		return E.New("unexpected Content-Range ", strconv.Quote(response.Header.Get("Content-Range")))
	}
	window := make([]byte, end-start)
	if _, err = io.ReadFull(response.Body, window); err != nil {
		return err
	}
	f.start, f.window = start, window
	return nil
}
