//go:build darwin && cgo

package phonemcp

import (
	"context"
	"crypto/subtle"
	_ "embed"
	"maps"
	"net"
	"net/http"
	"net/http/pprof"
	"net/netip"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/nekohasekai/go-sdk/mcp"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
)

//go:embed phone.d.ts
var phoneDeclarations string

//go:embed debug.d.ts
var debugDeclarations string

//go:embed workflows.d.ts
var workflowDeclarations string

var Declarations = phoneDeclarations + "\n" + debugDeclarations + "\n" + workflowDeclarations + "\n" + dialogDeclarations

const (
	sessionIdle   = time.Hour
	taskAfter     = time.Second
	progressEvery = 10 * time.Second

	// Claude Code polls a task no more often than every 250ms (Claude Code
	// 2.1.310 claude 0xfa90889).
	localPollInterval = 250 * time.Millisecond
)

const jsDescription = "Control the connected iPhone or iPad by running JavaScript, with top-level await, in a persistent session that holds the `phone` API. " +
	"Call `js_api` once for its declarations before the first script, and use only what they describe; its topics declare more when a task needs them. " +
	"Top-level bindings persist across calls and can be redeclared; `js_reset` discards them. " +
	"The value of the last expression statement is printed, as is anything passed to `print`; `phone.screenshot()` adds its image to the result. " +
	"This is plain JavaScriptCore, with no imports, Node APIs or network. `timeoutMs` is the script's time limit in milliseconds, none when left out."

type apiInput struct {
	Topic string `json:"topic,omitempty" jsonschema:"A topic to declare instead of the phone API"`
}

type Options struct {
	Token  string
	Path   string
	Logger logger.ContextLogger
}

type Server struct {
	runner *Runner
	logger logger.ContextLogger
	server *http.Server
	ctx    context.Context
	cancel context.CancelFunc
}

type jsInput struct {
	Code      string  `json:"code" jsonschema:"JavaScript to execute with top-level await."`
	TimeoutMs float64 `json:"timeoutMs,omitempty" jsonschema:"The script's time limit in milliseconds, none when left out."`
}

func New(runner *Runner, options Options) *Server {
	if options.Logger == nil {
		options.Logger = logger.NOP()
	}
	s := &Server{runner: runner, logger: options.Logger}
	s.ctx, s.cancel = context.WithCancel(context.Background())
	server := mcp.NewServer(&mcp.Implementation{Name: "phone", Title: "Phone", Version: "1.0.0"}, &mcp.ServerOptions{
		Capabilities: &mcp.ServerCapabilities{},
		Tasks: &mcp.TaskOptions{CreateAfter: taskAfter, PollInterval: func(req *mcp.CallToolRequest) time.Duration {
			if addr, _ := netip.ParseAddrPort(req.Extra.RemoteAddr); addr.Addr().IsLoopback() {
				return localPollInterval
			}
			return 0
		}},
	})
	mcp.AddTool(server, &mcp.Tool{
		Name:        "js",
		Title:       "Control the phone",
		Description: jsDescription,
		Meta:        mcp.Meta{"anthropic/alwaysLoad": true},
	}, s.js)
	topics := map[string]string{"debug": debugDeclarations}
	description := "Return the TypeScript declarations of `phone` and the other globals of `js`, or with `topic` those of " +
		"debug: the server's own log and recordings of what the device pushes"
	if runner.workflows != "" {
		topics["workflows"] = workflowDeclarations
		description += "; workflows: scripts saved on the device that run on their own, and their files"
	}
	if runner.dialog.Ask != nil {
		topics["dialog"] = dialogDeclarations
		description += "; dialog: questions a script asks the person on the device"
	}
	mcp.AddTool(server, &mcp.Tool{
		Name:        "js_api",
		Title:       "Phone JavaScript API",
		Description: description + ".",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true, IdempotentHint: true},
		Meta:        mcp.Meta{"anthropic/alwaysLoad": true},
	}, func(_ context.Context, _ *mcp.CallToolRequest, input apiInput) (*mcp.CallToolResult, any, error) {
		declarations := phoneDeclarations
		if input.Topic != "" {
			var found bool
			declarations, found = topics[input.Topic]
			if !found {
				return nil, nil, E.New("unknown topic ", strconv.Quote(input.Topic), "; the topics are ", strings.Join(slices.Sorted(maps.Keys(topics)), ", "))
			}
		}
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: declarations}}}, nil, nil
	})
	mcp.AddTool(server, &mcp.Tool{
		Name:        "js_reset",
		Title:       "Reset the phone JavaScript state",
		Description: "Interrupt the `js` calls in progress and clear the top-level bindings of earlier ones.",
	}, s.jsReset)
	mcpHandler := mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, &mcp.StreamableHTTPOptions{
		SessionTimeout: sessionIdle,
	})
	var handler http.Handler
	if options.Path == "" {
		mux := http.NewServeMux()
		mux.Handle("/", mcpHandler)
		mux.HandleFunc("/debug/pprof/", pprof.Index)
		mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
		mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
		mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
		mux.HandleFunc("/debug/pprof/trace", pprof.Trace)
		handler = mux
	} else {
		handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch {
			case r.URL.Path != options.Path:
				http.NotFound(w, r)
			// Quick Tunnels hold back the body of a GET text/event-stream response until it ends.
			case r.Method == http.MethodGet:
				w.Header().Set("Allow", "POST, DELETE")
				http.Error(w, http.StatusText(http.StatusMethodNotAllowed), http.StatusMethodNotAllowed)
			default:
				mcpHandler.ServeHTTP(w, r)
			}
		})
	}
	if options.Token != "" {
		authorized := handler
		handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			token, _, _ := r.BasicAuth()
			if subtle.ConstantTimeCompare([]byte(token), []byte(options.Token)) != 1 {
				w.Header().Set("WWW-Authenticate", `Basic realm="phone"`)
				http.Error(w, http.StatusText(http.StatusUnauthorized), http.StatusUnauthorized)
				return
			}
			authorized.ServeHTTP(w, r)
		})
	}
	s.server = &http.Server{Handler: http.NewCrossOriginProtection().Handler(handler), ReadHeaderTimeout: 10 * time.Second}
	return s
}

func (s *Server) Serve(listener net.Listener) error {
	return s.server.Serve(listener)
}

func (s *Server) Close() error {
	err := s.server.Close()
	s.cancel()
	return err
}

func (s *Server) js(ctx context.Context, req *mcp.CallToolRequest, input jsInput) (*mcp.CallToolResult, any, error) {
	if input.TimeoutMs < 0 {
		return nil, nil, E.New("timeoutMs must not be negative")
	}
	timeout := milliseconds(input.TimeoutMs)
	if token := req.Params.GetProgressToken(); token != nil {
		ticker := time.NewTicker(progressEvery)
		done := make(chan struct{})
		defer func() {
			close(done)
			ticker.Stop()
		}()
		go func() {
			for progress := 1; ; progress++ {
				select {
				case <-ticker.C:
				case <-done:
					return
				}
				err := req.Session.NotifyProgress(ctx, &mcp.ProgressNotificationParams{ProgressToken: token, Progress: float64(progress), Message: "running"})
				if err != nil {
					s.logger.Debug(E.Cause(err, "notify progress"))
				}
			}
		}()
	}
	return mcp.StartTaskFor(ctx, req, func(ctx context.Context, _ *mcp.ServerTask) (*mcp.CallToolResult, any, error) {
		ctx, cancel := context.WithCancel(ctx)
		defer cancel()
		defer context.AfterFunc(s.ctx, cancel)()
		started := time.Now()
		outcome := s.runner.execute(ctx, timeout, true, func(current *run) {
			current.dialog = s.runner.dialog
			s.runner.session(current, input.Code)
		})
		s.logger.Debug("js: ", len(input.Code), " bytes of code in ", time.Since(started), ", failed: ", outcome.failed)
		return outcome.result(), nil, nil
	})
}

func (s *Server) jsReset(ctx context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, any, error) {
	if err := s.runner.Reset(ctx); err != nil {
		return nil, nil, err
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "reset"}}}, nil, nil
}
