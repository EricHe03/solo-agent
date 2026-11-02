//go:build darwin && cgo

package automation

import (
	"context"
	"errors"
	"net/http"

	"github.com/coder/websocket"
	E "github.com/sagernet/sing/common/exceptions"
)

const webSocketReadLimit = 64 << 20

func (e *engine) watchWebSocket(ctx context.Context, call *operation, publish func(any, error)) error {
	var address string
	var protocols []string
	if err := call.decode(1, &address, &protocols); err != nil {
		return err
	}
	go func() {
		conn, response, err := websocket.Dial(ctx, address, &websocket.DialOptions{
			HTTPClient:   &http.Client{Transport: httpTransport},
			HTTPHeader:   http.Header{"User-Agent": {userAgent}},
			Subprotocols: protocols,
		})
		if err != nil {
			if ctx.Err() == nil {
				publish(nil, networkError(err, "connect to ", address))
			}
			return
		}
		if len(protocols) > 0 && conn.Subprotocol() == "" {
			_ = conn.CloseNow()
			publish(nil, networkError(E.New("the server selected none of the protocols"), "connect to ", address))
			return
		}
		conn.SetReadLimit(webSocketReadLimit)
		id := e.addResource(&resource{socket: conn, finish: func(error) error { return conn.CloseNow() }})
		publish(map[string]any{"type": "open", "socket": id, "protocol": conn.Subprotocol(), "extensions": response.Header.Get("Sec-WebSocket-Extensions")}, nil)
		for {
			kind, data, err := conn.Read(ctx)
			if err != nil {
				if taken, takeErr := e.takeResource(id); takeErr == nil {
					_ = taken.close(nil)
				}
				if ctx.Err() != nil {
					return
				}
				if closed, isClose := errors.AsType[websocket.CloseError](err); isClose {
					publish(map[string]any{"type": "close", "code": int(closed.Code), "reason": closed.Reason, "clean": true}, nil)
				} else {
					publish(map[string]any{"type": "close", "code": int(websocket.StatusAbnormalClosure), "reason": "", "clean": false, "error": Message(networkError(err, "read from ", address))}, nil)
				}
				return
			}
			if kind == websocket.MessageText {
				publish(map[string]any{"type": "message", "text": string(data)}, nil)
			} else {
				publish(map[string]any{"type": "message", "data": append([]byte{}, data...)}, nil)
			}
		}
	}()
	return nil
}

func (o *operation) socket(id string) (*websocket.Conn, error) {
	it, err := o.engine.resource(id)
	if err != nil {
		return nil, err
	}
	if it.socket == nil {
		return nil, E.Cause1(ErrInvalid, E.New("the resource is not a WebSocket"))
	}
	return it.socket, nil
}

func webSocketSend(ctx context.Context, call *operation) (any, error) {
	var id, data string
	var binary bool
	if err := call.decode(3, &id, &data, &binary); err != nil {
		return nil, err
	}
	kind, payload := websocket.MessageText, []byte(data)
	if binary {
		var err error
		if payload, err = call.engine.takeBlob(data); err != nil {
			return nil, err
		}
		kind = websocket.MessageBinary
	}
	conn, err := call.socket(id)
	if err != nil {
		return nil, err
	}
	return nil, conn.Write(ctx, kind, payload)
}

func webSocketClose(_ context.Context, call *operation) (any, error) {
	var id, reason string
	var code int
	if err := call.decode(3, &id, &code, &reason); err != nil {
		return nil, err
	}
	conn, err := call.socket(id)
	if err != nil {
		return nil, nil
	}
	_ = conn.Close(websocket.StatusCode(code), reason)
	return nil, nil
}
