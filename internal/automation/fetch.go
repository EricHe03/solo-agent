//go:build darwin && cgo

package automation

import (
	"bytes"
	"context"
	"io"
	"net/http"

	E "github.com/sagernet/sing/common/exceptions"
)

var httpClient = &http.Client{}

func fetch(ctx context.Context, call *operation) (any, error) {
	var request struct {
		URL      string      `json:"url"`
		Method   string      `json:"method"`
		Headers  [][2]string `json:"headers"`
		Body     string      `json:"body"`
		Redirect string      `json:"redirect"`
	}
	if err := call.decode(1, &request); err != nil {
		return nil, err
	}
	var body io.Reader
	if request.Body != "" {
		data, err := call.engine.takeBlob(request.Body)
		if err != nil {
			return nil, err
		}
		body = bytes.NewReader(data)
	}
	outgoing, err := http.NewRequestWithContext(ctx, request.Method, request.URL, body)
	if err != nil {
		return nil, E.Cause1(ErrInvalid, err)
	}
	for _, header := range request.Headers {
		outgoing.Header.Add(header[0], header[1])
	}
	client := httpClient
	redirected := false
	if request.Redirect != "follow" {
		client = &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error {
			if request.Redirect == "error" {
				return E.New("the response redirected while redirect is error")
			}
			return http.ErrUseLastResponse
		}}
	}
	response, err := client.Do(outgoing)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(response.Body)
	if err != nil {
		return nil, E.Cause(err, "read the response")
	}
	if response.Request != nil && response.Request.URL.String() != request.URL {
		redirected = true
	}
	headers := [][2]string{}
	for name, values := range response.Header {
		for _, value := range values {
			headers = append(headers, [2]string{name, value})
		}
	}
	out := map[string]any{
		"status": response.StatusCode, "statusText": http.StatusText(response.StatusCode), "url": response.Request.URL.String(),
		"redirected": redirected, "headers": headers, "body": "",
	}
	if len(data) > 0 {
		out["body"] = call.engine.putBlob(data)
	}
	return out, nil
}
