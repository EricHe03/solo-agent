//go:build darwin && cgo

package automation

import (
	"bufio"
	"bytes"
	"compress/flate"
	"compress/gzip"
	"compress/zlib"
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	userAgent     = "Swipt"
	redirectLimit = 20
)

var errNetwork = E.New("network error")

var httpTransport = func() *http.Transport {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.DisableCompression = true
	return transport
}()

var nullBodyStatuses = []int{http.StatusSwitchingProtocols, http.StatusEarlyHints, http.StatusNoContent, http.StatusResetContent, http.StatusNotModified}

func networkError(err error, message ...any) error {
	if urlError, isURL := errors.AsType[*url.Error](err); isURL {
		err = urlError.Err
	}
	return E.Cause1(errNetwork, E.Cause(err, message...))
}

type networkReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r networkReader) Read(p []byte) (int, error) {
	n, err := r.reader.Read(p)
	if err == nil || err == io.EOF {
		return n, err
	}
	if _, aborted := errors.AsType[*Failure](context.Cause(r.ctx)); aborted {
		return n, context.Cause(r.ctx)
	}
	if !E.IsMulti(err, errReleased, errEnded) {
		err = networkError(err, "read the response body")
	}
	return n, err
}

type uploadBody struct {
	*resource
}

func (b uploadBody) Read(p []byte) (int, error) {
	return b.reader.Read(p)
}

func (b uploadBody) Close() error {
	return b.close(io.ErrClosedPipe)
}

func fetch(ctx context.Context, call *operation) (any, error) {
	var request struct {
		URL      string      `json:"url"`
		Method   string      `json:"method"`
		Headers  [][2]string `json:"headers"`
		Body     string      `json:"body"`
		Stream   string      `json:"stream"`
		Redirect string      `json:"redirect"`
	}
	if err := call.decode(1, &request); err != nil {
		return nil, err
	}
	e := call.engine
	var data []byte
	var upload *resource
	switch {
	case request.Body != "":
		var err error
		if data, err = e.takeBlob(request.Body); err != nil {
			return nil, err
		}
	case request.Stream != "":
		var err error
		if upload, err = e.takeResource(request.Stream); err != nil {
			return nil, err
		}
		if upload.reader == nil {
			_ = upload.close(errReleased)
			return nil, E.Cause1(ErrInvalid, E.New("the request body is not readable"))
		}
	}
	dropUpload := func(err error) {
		if upload != nil {
			_ = upload.close(err)
			upload = nil
		}
	}
	requestCtx, cancel := context.WithCancelCause(e.ctx)
	newRequest := func(method, target string, header http.Header) (*http.Request, error) {
		var body io.Reader
		if data != nil {
			body = bytes.NewReader(data)
		}
		outgoing, err := http.NewRequestWithContext(requestCtx, method, target, body)
		if err != nil {
			return nil, E.Cause1(ErrInvalid, err)
		}
		if upload != nil {
			outgoing.Body = uploadBody{upload}
			outgoing.ContentLength = -1
		}
		outgoing.Header = header
		return outgoing, nil
	}
	header := make(http.Header)
	host := ""
	for _, field := range request.Headers {
		if strings.EqualFold(field[0], "host") {
			host = field[1]
		} else {
			header.Add(field[0], field[1])
		}
	}
	for name, value := range map[string]string{"User-Agent": userAgent, "Accept": "*/*", "Accept-Encoding": "gzip, deflate"} {
		if _, set := header[name]; !set {
			header.Set(name, value)
		}
	}
	outgoing, err := newRequest(request.Method, request.URL, header)
	if err != nil {
		cancel(nil)
		dropUpload(err)
		return nil, err
	}
	outgoing.Host = host
	uploaded := upload
	stop := context.AfterFunc(ctx, func() {
		cancel(context.Cause(ctx))
		if uploaded != nil {
			_ = uploaded.close(context.Cause(ctx))
		}
	})
	response, redirected, err := send(outgoing, request.Redirect, newRequest, dropUpload)
	if !stop() {
		if err == nil {
			_ = response.Body.Close()
		}
		cancel(nil)
		return nil, ctx.Err()
	}
	if err != nil {
		cancel(nil)
		dropUpload(err)
		return nil, networkError(err, "fetch ", request.URL)
	}
	final := *response.Request.URL
	final.Fragment, final.RawFragment = "", ""
	headers := [][2]string{}
	for name, values := range response.Header {
		for _, value := range values {
			headers = append(headers, [2]string{name, value})
		}
	}
	out := map[string]any{
		"status": response.StatusCode, "statusText": strings.TrimSpace(strings.TrimPrefix(response.Status, strconv.Itoa(response.StatusCode))),
		"url": final.String(), "redirected": redirected, "headers": headers, "body": "", "request": "",
	}
	if response.Request.Method == http.MethodHead || slices.Contains(nullBodyStatuses, response.StatusCode) {
		_ = response.Body.Close()
		cancel(nil)
		return out, nil
	}
	requestID := e.addResource(&resource{finish: func(abort error) error {
		cancel(abort)
		return nil
	}})
	out["request"] = requestID
	out["body"] = e.addResource(&resource{
		reader: networkReader{ctx: requestCtx, reader: decodeContent(response.Header.Values("Content-Encoding"), response.Body)},
		finish: func(abort error) error {
			if it, err := e.takeResource(requestID); err == nil {
				_ = it.close(abort)
			}
			cancel(abort)
			return response.Body.Close()
		},
	})
	return out, nil
}

var redirectClient = &http.Client{Transport: httpTransport, CheckRedirect: func(*http.Request, []*http.Request) error {
	return http.ErrUseLastResponse
}}

func send(outgoing *http.Request, mode string, newRequest func(method, target string, header http.Header) (*http.Request, error), dropUpload func(error)) (*http.Response, bool, error) {
	redirected := false
	for redirects := 0; ; redirects++ {
		response, err := redirectClient.Do(outgoing)
		if err != nil {
			return nil, false, err
		}
		location := response.Header.Get("Location")
		switch response.StatusCode {
		case http.StatusMovedPermanently, http.StatusFound, http.StatusSeeOther, http.StatusTemporaryRedirect, http.StatusPermanentRedirect:
		default:
			return response, redirected, nil
		}
		if mode == "manual" || location == "" {
			return response, redirected, nil
		}
		_ = response.Body.Close()
		target, err := outgoing.URL.Parse(location)
		switch {
		case err != nil:
			return nil, false, E.Cause(err, "parse the redirect location")
		case mode == "error":
			return nil, false, E.New("the response redirected, and the request's redirect is error")
		case redirects >= redirectLimit:
			return nil, false, E.New("the response redirected more than ", redirectLimit, " times")
		case target.Scheme != "http" && target.Scheme != "https":
			return nil, false, E.New("the response redirected to ", target.Scheme, ":")
		}
		method := outgoing.Method
		header := outgoing.Header.Clone()
		status := response.StatusCode
		if (status == http.StatusMovedPermanently || status == http.StatusFound) && method == http.MethodPost || status == http.StatusSeeOther && method != http.MethodGet && method != http.MethodHead {
			method = http.MethodGet
			dropUpload(io.ErrClosedPipe)
			for _, name := range []string{"Content-Encoding", "Content-Language", "Content-Location", "Content-Type"} {
				header.Del(name)
			}
		} else if outgoing.Body != nil && outgoing.GetBody == nil {
			return nil, false, E.New("the response redirected with ", status, ", which needs the request body again, but the body is a stream")
		}
		if target.Scheme != outgoing.URL.Scheme || target.Host != outgoing.URL.Host {
			for _, name := range []string{"Authorization", "Cookie", "Proxy-Authorization"} {
				header.Del(name)
			}
		}
		if outgoing, err = newRequest(method, target.String(), header); err != nil {
			return nil, false, err
		}
		if method == http.MethodGet || method == http.MethodHead {
			outgoing.Body, outgoing.GetBody, outgoing.ContentLength = nil, nil, 0
		}
		redirected = true
	}
}

func decodeContent(headers []string, body io.Reader) io.Reader {
	var codings []string
	for _, header := range headers {
		for coding := range strings.SplitSeq(header, ",") {
			coding = strings.ToLower(strings.TrimSpace(coding))
			switch coding {
			case "", "identity":
			case "gzip", "x-gzip", "deflate":
				codings = append(codings, coding)
			default:
				return body
			}
		}
	}
	reader := body
	for _, coding := range slices.Backward(codings) {
		reader = &lazyDecoder{source: reader, coding: coding}
	}
	return reader
}

type lazyDecoder struct {
	source  io.Reader
	coding  string
	decoder io.Reader
}

func (d *lazyDecoder) Read(p []byte) (int, error) {
	if d.decoder == nil {
		buffered := bufio.NewReader(d.source)
		switch d.coding {
		case "deflate":
			header, err := buffered.Peek(2)
			if err != nil {
				return 0, err
			}
			if header[0]&0x0f == 8 && (uint16(header[0])<<8|uint16(header[1]))%31 == 0 {
				decoder, err := zlib.NewReader(buffered)
				if err != nil {
					return 0, err
				}
				d.decoder = decoder
			} else {
				d.decoder = flate.NewReader(buffered)
			}
		default:
			decoder, err := gzip.NewReader(buffered)
			if err != nil {
				return 0, err
			}
			d.decoder = decoder
		}
	}
	return d.decoder.Read(p)
}
