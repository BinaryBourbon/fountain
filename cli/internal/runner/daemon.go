// Package runner is the `fountain runner` daemon: a machine the user owns,
// serving Fountain's sandbox contract over one outbound WebSocket (ADR 0022).
//
// The daemon dials Fountain, holds the socket, and answers JSON requests —
// create/get/destroy a sandbox, write a file, run a command, spawn a
// streaming one and pump its output back, re-attach with replay. What a
// sandbox *is* belongs to a Backend: `Process` makes it a directory on this
// machine and its commands local processes, with no isolation beyond that,
// on purpose and documented — this is trusted mode.
//
// The wire protocol is the one Fountain.Runners.Connection speaks (and the
// one Fountain.Runners.FakeDaemon executes in Fountain's own test suite):
//
//	→ {"id":7,"op":"spawn","name":"runner-…","cmd":"…","args":[…],"env":[[k,v]…],
//	    "dir":"…","stdin":true,"detachable":true}
//	← {"id":7,"ok":true,"result":{"session_id":"s-…"}}
//	← {"stream":"stdout","session_id":"s-…","data":"<base64>","replay_for":7}
//	← {"stream":"stdout","session_id":"s-…","data":"<base64>"}
//	← {"stream":"exit","session_id":"s-…","code":0}
//	← {"id":8,"ok":false,"error":"not_found","detail":"…"}
package runner

import (
	"encoding/json"
	"errors"
)

// Request is one frame from Fountain.
type Request struct {
	ID             int        `json:"id"`
	Op             string     `json:"op"`
	Name           string     `json:"name,omitempty"`
	Path           string     `json:"path,omitempty"`
	Data           string     `json:"data,omitempty"`
	Mode           *int       `json:"mode,omitempty"`
	Cmd            string     `json:"cmd,omitempty"`
	Args           []string   `json:"args,omitempty"`
	Env            [][]string `json:"env,omitempty"`
	Dir            string     `json:"dir,omitempty"`
	TimeoutMS      *int       `json:"timeout_ms,omitempty"`
	StderrToStdout bool       `json:"stderr_to_stdout,omitempty"`
	Stdin          bool       `json:"stdin,omitempty"`
	TTY            bool       `json:"tty,omitempty"`
	Detachable     bool       `json:"detachable,omitempty"`
	SessionID      string     `json:"session_id,omitempty"`
}

// Frame is anything the daemon sends: a reply (ID set) or a stream frame.
type Frame map[string]any

// OpError is a request refused with one of the contract's error codes.
type OpError struct {
	Code   string
	Detail string
}

func (e *OpError) Error() string { return e.Code + ": " + e.Detail }

func notFound(detail string) error     { return &OpError{Code: "not_found", Detail: detail} }
func invalid(detail string) error      { return &OpError{Code: "invalid", Detail: detail} }
func commandExited() error             { return &OpError{Code: "command_exited"} }
func notSupported(detail string) error { return &OpError{Code: "not_supported", Detail: detail} }
func unavailable(detail string) error  { return &OpError{Code: "unavailable", Detail: detail} }
func writeFailed(detail string) error  { return &OpError{Code: "write_failed", Detail: detail} }

// Emitter carries frames back to Fountain. The connection supplies one; tests
// supply a recorder. It must be safe for concurrent use.
type Emitter interface {
	Emit(Frame)
}

// Logger is the slice of *slog.Logger the daemon uses.
type Logger interface {
	Info(msg string, args ...any)
	Warn(msg string, args ...any)
	Debug(msg string, args ...any)
}

// Daemon routes requests to a Backend.
type Daemon struct {
	Backend Backend
	Log     Logger
}

// New builds a daemon over the process backend, rooted at root.
func New(root string, log Logger) (*Daemon, error) {
	p, err := NewProcess(root, log)
	if err != nil {
		return nil, err
	}
	return NewWithBackend(p, log), nil
}

// NewWithBackend builds a daemon over any backend.
func NewWithBackend(b Backend, log Logger) *Daemon {
	return &Daemon{Backend: b, Log: log}
}

// Handle answers one request. It returns the reply's result and, for spawn
// and attach, an `after` to run once the reply has been written — the
// journal replay must follow the reply, never precede it.
func (d *Daemon) Handle(req Request, emit Emitter) (result map[string]any, after func(), err error) {
	switch req.Op {
	case "create":
		return d.Backend.Create(req)
	case "get":
		return d.Backend.Get(req)
	case "destroy":
		return d.Backend.Destroy(req)
	case "list":
		return d.Backend.List()
	case "suspend":
		return d.Backend.Suspend(req)
	case "resume":
		return d.Backend.Resume(req)
	case "write_file":
		return d.Backend.WriteFile(req)
	case "exec":
		return d.Backend.Exec(req)
	case "spawn":
		return d.Backend.Spawn(req, emit)
	case "stdin":
		return d.Backend.Stdin(req)
	case "stdin_close":
		return d.Backend.StdinClose(req)
	case "detach":
		return d.Backend.Detach(req)
	case "list_sessions":
		return d.Backend.ListSessions(req)
	case "attach":
		return d.Backend.Attach(req, emit)
	default:
		return nil, nil, notSupported(req.Op)
	}
}

// StopAll terminates every live session (daemon shutdown).
func (d *Daemon) StopAll() { d.Backend.StopAll() }

// Reply renders a request's outcome as the reply frame.
func Reply(id int, result map[string]any, err error) Frame {
	if err == nil {
		if result == nil {
			result = map[string]any{}
		}
		return Frame{"id": id, "ok": true, "result": result}
	}
	var op *OpError
	if errors.As(err, &op) {
		return Frame{"id": id, "ok": false, "error": op.Code, "detail": op.Detail}
	}
	return Frame{"id": id, "ok": false, "error": "provider", "detail": err.Error()}
}

// Marshal is the JSON of a frame.
func Marshal(f Frame) []byte {
	b, _ := json.Marshal(f)
	return b
}
