package libSwipt

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
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
	"github.com/swipt-automation/swipt/internal/automation"
)

const (
	sourceLimit        = 4 << 20
	swipletIdleTimeout = 15 * time.Second
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

func (d *SwipletDownloader) Download(link string, destination string, etag string, version string, versionCode int64, checksum string) *SwipletDownload {
	download, err := d.download(link, destination, etag, version, versionCode, checksum)
	switch {
	case err == nil:
		return download
	case E.IsTimeout(err):
		return &SwipletDownload{ErrorCode: SwipletErrorTimeout, ErrorMessage: err.Error()}
	default:
		return &SwipletDownload{ErrorCode: SwipletErrorFailed, ErrorMessage: err.Error()}
	}
}

func (d *SwipletDownloader) download(link string, destination string, etag string, version string, versionCode int64, checksum string) (*SwipletDownload, error) {
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
	download := &SwipletDownload{URL: response.Request.URL.String(), EntityTag: response.Header.Get("ETag")}
	switch response.StatusCode {
	case http.StatusNotModified:
		return download, nil
	case http.StatusOK:
	default:
		return nil, E.New(response.Status)
	}
	name := response.Request.URL.Path
	if _, params, err := mime.ParseMediaType(response.Header.Get("Content-Disposition")); err == nil && params["filename"] != "" {
		name = params["filename"]
	}
	name = path.Base(name)
	download.Name = strings.TrimSuffix(name, path.Ext(name))
	file, err := os.Create(destination + ".download")
	if err != nil {
		return nil, err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	hash := sha256.New()
	size, err := io.Copy(io.MultiWriter(file, hash), response.Body)
	if err != nil {
		return nil, err
	}
	if checksum != "" && !strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), checksum) {
		return nil, E.New("the download doesn't match the checksum")
	}
	return finish(download, file, size, link, destination, version, versionCode)
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

type source struct {
	Swiplets []json.RawMessage `json:"swiplets"`
}

func finish(download *SwipletDownload, archive io.ReaderAt, size int64, link string, destination string, version string, versionCode int64) (*SwipletDownload, error) {
	reader, err := zip.NewReader(archive, size)
	if err != nil {
		return nil, E.Cause(err, "open the archive")
	}
	contents, err := automation.ReadArchive(reader)
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
	err = copyArchive(writer, contents, link)
	if err = E.Errors(err, writer.Close(), file.Close()); err != nil {
		return nil, err
	}
	return download, nil
}

func copyArchive(writer *zip.Writer, contents automation.Archive, link string) error {
	for _, source := range contents.Files {
		if source.Name == automation.ManifestFile && contents.Manifest.UpdateURL == "" {
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
