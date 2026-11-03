package cloudflare

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	F "github.com/sagernet/sing/common/format"

	"github.com/google/uuid"
)

const (
	apiBase         = "https://api.cloudflare.com/client/v4"
	loginBase       = "https://dash.cloudflare.com/argotunnel"
	loginStore      = "https://login.cloudflareaccess.org/"
	loginTimeout    = 10 * time.Minute
	loginRetryDelay = time.Second
	loginGrace      = 5 * time.Second
	userAgent       = "swipt"
)

var (
	apiClient   = &http.Client{Timeout: 30 * time.Second}
	loginClient = &http.Client{Timeout: time.Minute}
)

type Account struct {
	ZoneID    string `json:"zoneID"`
	AccountID string `json:"accountID"`
	APIToken  string `json:"apiToken"`
}

func ParseAccount(content string) (Account, error) {
	var account Account
	err := json.Unmarshal([]byte(content), &account)
	if err != nil {
		return Account{}, E.Cause(err, "cloudflare: parse account")
	}
	if account.ZoneID == "" || account.AccountID == "" || account.APIToken == "" {
		return Account{}, E.New("cloudflare: incomplete account")
	}
	return account, nil
}

func (a Account) request(ctx context.Context, method string, path string, body any, result any) error {
	var reader io.Reader
	if body != nil {
		content, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(content)
	}
	request, err := http.NewRequestWithContext(ctx, method, apiBase+path, reader)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+a.APIToken)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("User-Agent", userAgent)
	response, err := apiClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	var envelope struct {
		Success bool `json:"success"`
		Errors  []struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"errors"`
		Result json.RawMessage `json:"result"`
	}
	err = json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&envelope)
	if err != nil {
		return E.Cause(err, "cloudflare: decode the response to ", path, " (", response.Status, ")")
	}
	if !envelope.Success {
		messages := make([]string, 0, len(envelope.Errors))
		for _, item := range envelope.Errors {
			messages = append(messages, F.ToString(item.Message, " (", item.Code, ")"))
		}
		return E.New(response.Status, ": ", strings.Join(messages, "; "))
	}
	if result == nil {
		return nil
	}
	return json.Unmarshal(envelope.Result, result)
}

func (a Account) ZoneName(ctx context.Context) (string, error) {
	var zone struct {
		Name string `json:"name"`
	}
	err := a.request(ctx, http.MethodGet, "/zones/"+a.ZoneID, nil, &zone)
	if err != nil {
		return "", E.Cause(err, "cloudflare: read zone")
	}
	return zone.Name, nil
}

func (a Account) createTunnel(ctx context.Context) (tunnelState, error) {
	secret := make([]byte, 32)
	rand.Read(secret)
	suffix := make([]byte, 4)
	rand.Read(suffix)
	var created struct {
		ID uuid.UUID `json:"id"`
	}
	err := a.request(ctx, http.MethodPost, "/accounts/"+a.AccountID+"/cfd_tunnel", map[string]any{
		"name":          "swipt-" + hex.EncodeToString(suffix),
		"tunnel_secret": secret,
		"config_src":    "local",
	}, &created)
	if err != nil {
		return tunnelState{}, E.Cause(err, "cloudflare: create tunnel")
	}
	return tunnelState{ID: created.ID, AccountTag: a.AccountID, Secret: secret}, nil
}

func (a Account) routeTunnel(ctx context.Context, tunnelID uuid.UUID, hostname string) error {
	err := a.request(ctx, http.MethodPut, "/zones/"+a.ZoneID+"/tunnels/"+tunnelID.String()+"/routes", map[string]any{
		"type":               "dns",
		"user_hostname":      hostname,
		"overwrite_existing": true,
	}, nil)
	if err != nil {
		return E.Cause(err, "cloudflare: route ", hostname)
	}
	return nil
}

type Login struct {
	key    string
	ctx    context.Context
	cancel context.CancelFunc
}

func NewLogin() *Login {
	key := make([]byte, 32)
	rand.Read(key)
	ctx, cancel := context.WithTimeout(context.Background(), loginTimeout)
	return &Login{key: base64.URLEncoding.EncodeToString(key), ctx: ctx, cancel: cancel}
}

func (l *Login) URL() string {
	return loginBase + "?" + url.Values{"aud": {""}, "callback": {loginStore + l.key}}.Encode()
}

func (l *Login) Cancel() {
	time.AfterFunc(loginGrace, l.cancel)
}

func (l *Login) Wait() (Account, error) {
	defer l.cancel()
	for {
		content, err := l.poll()
		if err != nil {
			return Account{}, err
		}
		if content != nil {
			return decodeOriginCertificate(content)
		}
		select {
		case <-l.ctx.Done():
			return Account{}, l.ctx.Err()
		case <-time.After(loginRetryDelay):
		}
	}
}

func (l *Login) poll() ([]byte, error) {
	request, err := http.NewRequestWithContext(l.ctx, http.MethodGet, loginStore+l.key, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", userAgent)
	response, err := loginClient.Do(request)
	if err != nil {
		if l.ctx.Err() != nil {
			return nil, l.ctx.Err()
		}
		return nil, nil
	}
	defer response.Body.Close()
	switch {
	case response.StatusCode >= http.StatusInternalServerError:
		return nil, E.New("cloudflare: login: ", response.Status)
	case response.StatusCode != http.StatusOK:
		return nil, nil
	}
	content, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return nil, E.Cause(err, "cloudflare: read login certificate")
	}
	return content, nil
}

func decodeOriginCertificate(content []byte) (Account, error) {
	for {
		var block *pem.Block
		block, content = pem.Decode(content)
		if block == nil {
			return Account{}, E.New("cloudflare: login certificate has no token")
		}
		if block.Type != "ARGO TUNNEL TOKEN" {
			continue
		}
		var account Account
		err := json.Unmarshal(block.Bytes, &account)
		if err != nil {
			return Account{}, E.Cause(err, "cloudflare: decode login certificate")
		}
		if account.ZoneID == "" || account.AccountID == "" || account.APIToken == "" {
			return Account{}, E.New("cloudflare: incomplete login certificate")
		}
		return account, nil
	}
}
