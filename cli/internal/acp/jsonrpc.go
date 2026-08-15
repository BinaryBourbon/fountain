// Package acp implements the agent half of the Agent Client Protocol: the
// side an editor spawns, speaks JSON-RPC to over stdio, and expects session
// updates back from.
//
// It is the upward direction of [ADR 0015]. The downward direction — Fountain
// as an ACP *client* of the coding agent running in a sprite — lives in the
// Elixir server (Fountain.Runtimes.ACP), and that is deliberate: the four
// runtime dialects are translated once, on the server, at the only boundary
// that knows which runtime produced the bytes. Nothing in this package parses
// a runtime dialect, and nothing in it ever should.
//
// [ADR 0015]: https://github.com/BinaryBourbon/fountain/blob/main/decisions/0015-fountain-as-an-acp-agent.md
package acp

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"strings"
	"sync"
)

// JSON-RPC 2.0 error codes, plus the ones ACP leans on.
const (
	CodeParseError     = -32700
	CodeInvalidRequest = -32600
	CodeMethodNotFound = -32601
	CodeInvalidParams  = -32602
	CodeInternalError  = -32603
	// CodeAuthRequired is ACP's own: the client must call `authenticate`
	// before the session methods will answer.
	CodeAuthRequired = -32000
)

// Error is a JSON-RPC error the handler wants reported verbatim. Any other
// error from a handler becomes an internal error with its message attached.
type Error struct {
	Code    int
	Message string
	Data    any
}

func (e *Error) Error() string { return fmt.Sprintf("jsonrpc %d: %s", e.Code, e.Message) }

// Errorf builds an *Error with a formatted message.
func Errorf(code int, format string, a ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, a...)}
}

// Handler answers one incoming message.
//
// Request returns the value to encode as `result`; returning an *Error sends
// that error back to the client. Notify is fire-and-forget: JSON-RPC forbids
// a response to a notification, so an error from it can only be logged.
type Handler interface {
	Request(ctx context.Context, method string, params json.RawMessage) (any, error)
	Notify(ctx context.Context, method string, params json.RawMessage)
}

// message is the wire shape of everything arriving on stdin. The four
// JSON-RPC kinds are distinguished by which fields are present, so they share
// one struct rather than four with a discriminator that ACP does not send.
type message struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
}

// Conn is one ACP connection: line-delimited JSON in, line-delimited JSON out.
//
// Writes are serialised because the agent has two writers — request responses
// and, from the session methods, unsolicited `session/update` notifications
// forwarded from a stream goroutine. Two interleaved writes produce one
// unparseable line, which an editor reports as the agent crashing.
type Conn struct {
	in  *bufio.Reader
	out io.Writer
	log *slog.Logger

	mu       sync.Mutex // guards out
	inflight sync.WaitGroup
}

// NewConn wires a connection to the given streams. For `fountain acp` these
// are the process's stdin and stdout: stdout carries the protocol and nothing
// else, which is why every diagnostic in this package goes to the logger
// (stderr) instead.
func NewConn(in io.Reader, out io.Writer, log *slog.Logger) *Conn {
	return &Conn{in: bufio.NewReader(in), out: out, log: log}
}

// Serve reads messages until stdin closes or ctx is cancelled.
//
// A closed stdin is how an editor says "we're done" — it is a clean exit, not
// an error. Serve returns nil for it, and for a cancelled context.
func (c *Conn) Serve(ctx context.Context, h Handler) error {
	// Handlers run on their own goroutines (see dispatch). When Serve ends —
	// the editor closed stdin, or the process was signalled — their context is
	// cancelled first, so a `session/prompt` blocked on a stream stops reading
	// one nobody is listening to, and then we wait for them rather than
	// returning while goroutines still hold the output pipe. The turn itself
	// keeps running server-side; that is the whole point of Fountain.
	hctx, cancel := context.WithCancel(ctx)
	defer func() {
		cancel()
		c.inflight.Wait()
	}()

	for {
		if err := ctx.Err(); err != nil {
			return nil
		}

		line, err := c.in.ReadString('\n')
		if len(line) > 0 {
			c.dispatch(hctx, h, line)
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
	}
}

// dispatch handles one framed line.
//
// A line that is not JSON is logged and skipped rather than fatal. The server
// peer made the same call for the same reason (see Protocol.feed/2's "why the
// decode failure is a value"): npm deprecation notices and Node stack traces
// turn up on pipes that are supposed to carry only protocol, and killing the
// connection over somebody else's diagnostic is the wrong trade.
func (c *Conn) dispatch(ctx context.Context, h Handler, line string) {
	if strings.TrimSpace(line) == "" {
		return
	}

	var msg message
	if err := json.Unmarshal([]byte(line), &msg); err != nil {
		c.log.Warn("dropping unparseable line from client", "err", err, "line", truncate(line, 256))
		return
	}

	switch {
	case msg.Method == "" && len(msg.ID) > 0:
		// A response to something we sent. Nothing in this package sends
		// requests yet; when session/request_permission forwarding lands
		// (#708) this is where its answers arrive.
		c.log.Debug("ignoring response to a request we did not send", "id", string(msg.ID))

	case msg.Method == "":
		c.log.Warn("dropping message with no method and no id", "line", truncate(line, 256))

	case len(msg.ID) == 0:
		h.Notify(ctx, msg.Method, msg.Params)

	default:
		// Each request runs on its own goroutine because `session/prompt`
		// blocks for the whole turn — minutes, sometimes — and a connection
		// that stopped reading during it would be deaf to exactly the messages
		// a developer sends when a turn is taking too long: `session/cancel`
		// (#704), or a prompt in another session. Responses may then be
		// written out of order, which JSON-RPC allows: the id correlates them.
		c.inflight.Add(1)
		go func() {
			defer c.inflight.Done()
			result, err := h.Request(ctx, msg.Method, msg.Params)
			c.respond(msg, result, err)
		}()
	}
}

func (c *Conn) respond(msg message, result any, err error) {
	if err != nil {
		var rpcErr *Error
		if !errors.As(err, &rpcErr) {
			rpcErr = &Error{Code: CodeInternalError, Message: err.Error()}
		}
		c.log.Warn("request failed", "method", msg.Method, "code", rpcErr.Code, "err", rpcErr.Message)
		c.write(map[string]any{
			"jsonrpc": "2.0",
			"id":      msg.ID,
			"error":   errorPayload(rpcErr),
		})
		return
	}

	if result == nil {
		// ACP methods that answer with nothing (`authenticate`,
		// `session/cancel`) still owe a response; `{}` is a result, `null`
		// reads to some clients as a missing one.
		result = struct{}{}
	}
	c.write(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": result})
}

func errorPayload(e *Error) map[string]any {
	payload := map[string]any{"code": e.Code, "message": e.Message}
	if e.Data != nil {
		payload["data"] = e.Data
	}
	return payload
}

// Notify sends a notification to the client. This is how `session/update`
// will leave the process once the stream forwarding lands (#701).
func (c *Conn) Notify(method string, params any) {
	msg := map[string]any{"jsonrpc": "2.0", "method": method}
	if params != nil {
		msg["params"] = params
	}
	c.write(msg)
}

func (c *Conn) write(v any) {
	encoded, err := json.Marshal(v)
	if err != nil {
		// Marshalling our own message failed: writing a half-encoded line
		// would corrupt the stream for every message after it.
		c.log.Error("failed to encode outgoing message", "err", err)
		return
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if _, err := c.out.Write(append(encoded, '\n')); err != nil {
		c.log.Error("failed to write to client", "err", err)
	}
}

func truncate(s string, n int) string {
	s = strings.TrimRight(s, "\r\n")
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
