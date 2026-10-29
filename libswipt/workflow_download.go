package libSwipt

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/binary"
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

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/phonemcp"
)

const (
	workflowHeadSize    = 64 << 10
	workflowIdleTimeout = 15 * time.Second
	remoteWindowSize    = 64 << 10
	remoteWindowLimit   = 4 << 20
	localFileSignature  = 0x04034b50
)

var workflowClient = func() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.DialContext = func(ctx context.Context, network string, address string) (net.Conn, error) {
		conn, err := (&net.Dialer{Timeout: workflowIdleTimeout}).DialContext(ctx, network, address)
		if err != nil {
			return nil, err
		}
		return &idleConn{conn}, nil
	}
	transport.TLSHandshakeTimeout = workflowIdleTimeout
	return &http.Client{Transport: transport}
}()

type idleConn struct {
	net.Conn
}

func (c *idleConn) Read(p []byte) (int, error) {
	if err := c.SetReadDeadline(time.Now().Add(workflowIdleTimeout)); err != nil {
		return 0, err
	}
	return c.Conn.Read(p)
}

func (c *idleConn) Write(p []byte) (int, error) {
	if err := c.SetWriteDeadline(time.Now().Add(workflowIdleTimeout)); err != nil {
		return 0, err
	}
	return c.Conn.Write(p)
}

type WorkflowDownload struct {
	URL       string
	EntityTag string
	Name      string
	Version   string

	ErrorCode    int32
	ErrorMessage string
}

const (
	WorkflowErrorNone    int32 = 0
	WorkflowErrorFailed  int32 = 1
	WorkflowErrorTimeout int32 = 2
)

type WorkflowDownloader struct {
	ctx    context.Context
	cancel context.CancelFunc
}

func NewWorkflowDownloader() *WorkflowDownloader {
	ctx, cancel := context.WithCancel(context.Background())
	return &WorkflowDownloader{ctx: ctx, cancel: cancel}
}

func (d *WorkflowDownloader) Cancel() {
	d.cancel()
}

func (d *WorkflowDownloader) Download(link string, destination string, etag string, version string) *WorkflowDownload {
	download, err := d.download(link, destination, etag, version)
	switch {
	case err == nil:
		return download
	case E.IsTimeout(err):
		return &WorkflowDownload{ErrorCode: WorkflowErrorTimeout, ErrorMessage: err.Error()}
	default:
		return &WorkflowDownload{ErrorCode: WorkflowErrorFailed, ErrorMessage: err.Error()}
	}
}

func (d *WorkflowDownloader) download(link string, destination string, etag string, version string) (*WorkflowDownload, error) {
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
	request.Header.Set("Range", "bytes=0-"+strconv.Itoa(workflowHeadSize-1))
	if etag != "" {
		request.Header.Set("If-None-Match", etag)
	}
	response, err := workflowClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	download := &WorkflowDownload{URL: response.Request.URL.String(), EntityTag: response.Header.Get("ETag")}
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
	head, err := io.ReadAll(io.LimitReader(response.Body, workflowHeadSize))
	if err != nil {
		return nil, err
	}
	var remote *remoteFile
	content := io.MultiReader(bytes.NewReader(head), response.Body)
	if response.StatusCode == http.StatusPartialContent {
		if remote, err = newRemoteFile(d.ctx, response, head); err != nil {
			return nil, err
		}
		content = io.NewSectionReader(remote, 0, remote.size)
	}
	if !bytes.HasPrefix(head, archiveMagic) {
		if folder != "" {
			return nil, E.New("the file is not a ZIP archive")
		}
		if version != "" && !phonemcp.HeaderTruncated(string(head)) {
			if download.Version = phonemcp.ReadHeader(string(head)).Version; download.Version == "" || download.Version == version {
				return download, nil
			}
		}
		entry, err := io.ReadAll(content)
		if err != nil {
			return nil, err
		}
		download.Version = phonemcp.ReadHeader(string(entry)).Version
		return download, os.WriteFile(destination, entry, 0o644)
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
	reader, err := zip.NewReader(archive, size)
	if err != nil {
		return nil, E.Cause(err, "open the archive")
	}
	entry, sources, err := readArchive(reader, folder)
	if err != nil {
		return nil, err
	}
	if download.Version = phonemcp.ReadHeader(string(entry)).Version; version != "" && (download.Version == "" || download.Version == version) {
		return download, nil
	}
	file, err := os.Create(destination)
	if err != nil {
		return nil, err
	}
	writer := zip.NewWriter(file)
	err = copyArchive(writer, sources)
	if err = E.Errors(err, writer.Close(), file.Close()); err != nil {
		return nil, err
	}
	return download, nil
}

func copyArchive(writer *zip.Writer, sources []archiveSource) error {
	for _, source := range sources {
		header := source.file.FileHeader
		header.Name, header.Extra = source.name, nil
		output, err := writer.CreateRaw(&header)
		if err != nil {
			return err
		}
		input, err := source.file.OpenRaw()
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
	response, err := workflowClient.Do(request)
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
