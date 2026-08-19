// Package runner is the `fountain runner` daemon: a machine the user owns,
// serving Fountain's sandbox contract over one outbound WebSocket (ADR 0022).
//
// The daemon dials Fountain, holds the socket, and answers JSON requests —
// create/get/destroy a sandbox, write a file, run a command, spawn a
// streaming one and pump its output back, re-attach with replay — against a
// root directory on the local disk. A sandbox is a directory; commands run
// as the daemon's user with HOME pointed at that directory. There is no
// isolation beyond that, on purpose and documented: this is trusted mode.
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
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// spriteHome is the home directory every Fountain provisioning script and
// runtime assumes (the Sprites base image; the E2B/Daytona images recreate
// it). The daemon maps it to the sandbox directory in file paths, working
// directories, and command arguments, so those scripts land inside the
// sandbox without a Linux user of that name existing on this machine.
const spriteHome = "/home/sprite"

// suspendedMarker sits in a sandbox directory while it is parked: suspend
// stops its processes and leaves the marker, resume removes it.
const suspendedMarker = ".fountain-suspended"

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

// Daemon owns the sandbox root and the live sessions.
type Daemon struct {
	Root     string
	RealHome string
	Log      Logger

	mu       sync.Mutex
	sessions map[string]*Session // by session id
	seq      int
}

// Logger is the slice of *slog.Logger the daemon uses.
type Logger interface {
	Info(msg string, args ...any)
	Warn(msg string, args ...any)
	Debug(msg string, args ...any)
}

// New builds a daemon over root, creating it if needed.
func New(root string, log Logger) (*Daemon, error) {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, fmt.Errorf("create sandbox root %s: %w", root, err)
	}
	home, _ := os.UserHomeDir()
	return &Daemon{Root: root, RealHome: home, Log: log, sessions: map[string]*Session{}}, nil
}

// Handle answers one request. It returns the reply's result and, for spawn
// and attach, an `after` to run once the reply has been written — the
// journal replay must follow the reply, never precede it.
func (d *Daemon) Handle(req Request, emit Emitter) (result map[string]any, after func(), err error) {
	switch req.Op {
	case "create":
		return d.create(req)
	case "get":
		return d.get(req)
	case "destroy":
		return d.destroy(req)
	case "list":
		return d.list()
	case "suspend":
		return d.suspend(req)
	case "resume":
		return d.resume(req)
	case "write_file":
		return d.writeFile(req)
	case "exec":
		return d.exec(req)
	case "spawn":
		return d.spawn(req, emit)
	case "stdin":
		return d.stdin(req)
	case "stdin_close":
		return d.stdinClose(req)
	case "detach":
		return d.detach(req)
	case "list_sessions":
		return d.listSessions(req)
	case "attach":
		return d.attach(req, emit)
	default:
		return nil, nil, notSupported(req.Op)
	}
}

// ── sandboxes ────────────────────────────────────────────────────────────────

func (d *Daemon) dir(name string) (string, error) {
	if name == "" || strings.ContainsAny(name, "/\\") || name == "." || name == ".." ||
		strings.HasPrefix(name, ".") {
		return "", invalid("bad sandbox name")
	}
	return filepath.Join(d.Root, name), nil
}

// existingDir is dir plus a presence check.
func (d *Daemon) existingDir(name string) (string, error) {
	dir, err := d.dir(name)
	if err != nil {
		return "", err
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return "", notFound("no sandbox " + name)
	}
	return dir, nil
}

func (d *Daemon) create(req Request) (map[string]any, func(), error) {
	dir, err := d.dir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	// Idempotent-adopting: an existing directory is the same sandbox.
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, nil, unavailable(err.Error())
	}
	return map[string]any{}, nil, nil
}

func (d *Daemon) get(req Request) (map[string]any, func(), error) {
	dir, err := d.existingDir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	status := "running"
	if _, err := os.Stat(filepath.Join(dir, suspendedMarker)); err == nil {
		status = "suspended"
	}
	return map[string]any{"status": status, "path": dir}, nil, nil
}

func (d *Daemon) destroy(req Request) (map[string]any, func(), error) {
	dir, err := d.dir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	d.stopSessions(req.Name)
	d.mu.Lock()
	for id, s := range d.sessions {
		if s.sandbox == req.Name {
			delete(d.sessions, id)
		}
	}
	d.mu.Unlock()
	// Already gone is ok.
	if err := os.RemoveAll(dir); err != nil {
		return nil, nil, unavailable(err.Error())
	}
	return map[string]any{}, nil, nil
}

func (d *Daemon) list() (map[string]any, func(), error) {
	entries, err := os.ReadDir(d.Root)
	if err != nil {
		return nil, nil, unavailable(err.Error())
	}
	names := []string{}
	for _, e := range entries {
		if e.IsDir() && !strings.HasPrefix(e.Name(), ".") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return map[string]any{"names": names}, nil, nil
}

func (d *Daemon) suspend(req Request) (map[string]any, func(), error) {
	dir, err := d.existingDir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	// Parking = stop what is running, keep the disk. Nothing else costs
	// anything on a machine that stays up.
	d.stopSessions(req.Name)
	if err := os.WriteFile(filepath.Join(dir, suspendedMarker), nil, 0o600); err != nil {
		return nil, nil, unavailable(err.Error())
	}
	return map[string]any{}, nil, nil
}

func (d *Daemon) resume(req Request) (map[string]any, func(), error) {
	dir, err := d.existingDir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	_ = os.Remove(filepath.Join(dir, suspendedMarker))
	return map[string]any{}, nil, nil
}

// ── files ────────────────────────────────────────────────────────────────────

// mapPath resolves a path Fountain names into the sandbox: `/home/sprite/…`
// and relative paths land inside the sandbox directory; other absolute paths
// are the host's (trusted mode — /tmp is /tmp).
func mapPath(dir, p string) string {
	switch {
	case p == spriteHome:
		return dir
	case strings.HasPrefix(p, spriteHome+"/"):
		return filepath.Join(dir, strings.TrimPrefix(p, spriteHome+"/"))
	case p == "~":
		return dir
	case strings.HasPrefix(p, "~/"):
		return filepath.Join(dir, p[2:])
	case filepath.IsAbs(p):
		return p
	case p == "":
		return dir
	default:
		return filepath.Join(dir, p)
	}
}

// mapArg rewrites the literal /home/sprite wherever it appears in a command
// or argument, so `bin=/home/sprite/.local/bin/x` in a `bash -lc` script
// resolves inside the sandbox too.
func mapArg(dir, arg string) string {
	return strings.ReplaceAll(arg, spriteHome, dir)
}

func (d *Daemon) writeFile(req Request) (map[string]any, func(), error) {
	dir, err := d.existingDir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	data, err := base64.StdEncoding.DecodeString(req.Data)
	if err != nil {
		return nil, nil, invalid("data is not base64")
	}
	target := mapPath(dir, req.Path)
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return nil, nil, writeFailed(err.Error())
	}
	mode := os.FileMode(0o644)
	if req.Mode != nil {
		mode = os.FileMode(*req.Mode)
	}
	if err := os.WriteFile(target, data, mode); err != nil {
		return nil, nil, writeFailed(err.Error())
	}
	// WriteFile's mode is subject to umask; a requested mode is a promise.
	if req.Mode != nil {
		_ = os.Chmod(target, mode)
	}
	return map[string]any{}, nil, nil
}

// ── commands ─────────────────────────────────────────────────────────────────

// command builds the exec.Cmd for a request inside a sandbox: HOME is the
// sandbox, PATH gains the sandbox's own bin dirs, npm installs globally into
// the sandbox, and the request's env pairs win over all of it.
func (d *Daemon) command(ctx context.Context, dir string, req Request) *exec.Cmd {
	args := make([]string, len(req.Args))
	for i, a := range req.Args {
		args[i] = mapArg(dir, a)
	}
	env := d.env(dir, req.Env)
	// os/exec resolves a bare command name against the *daemon's* PATH; the
	// agent CLIs provisioning installs live on the sandbox's PATH
	// (`<sandbox>/.local/bin`, `.npm-global/bin`), so resolve there.
	cmd := exec.CommandContext(ctx, lookPath(mapArg(dir, req.Cmd), env), args...)
	cmd.Dir = mapPath(dir, req.Dir)
	if st, err := os.Stat(cmd.Dir); err != nil || !st.IsDir() {
		cmd.Dir = dir
	}
	cmd.Env = env
	return cmd
}

// lookPath resolves name against the PATH inside env (not the process's).
// A name that resolves nowhere is returned unchanged so the failure reads
// as "not found" when the command runs.
func lookPath(name string, env []string) string {
	if strings.Contains(name, "/") {
		return name
	}
	for _, kv := range env {
		if !strings.HasPrefix(kv, "PATH=") {
			continue
		}
		for _, p := range filepath.SplitList(strings.TrimPrefix(kv, "PATH=")) {
			if p == "" {
				continue
			}
			candidate := filepath.Join(p, name)
			if st, err := os.Stat(candidate); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
				return candidate
			}
		}
		break
	}
	return name
}

func (d *Daemon) env(dir string, pairs [][]string) []string {
	base := map[string]string{}
	order := []string{}
	set := func(k, v string) {
		if _, ok := base[k]; !ok {
			order = append(order, k)
		}
		base[k] = v
	}
	for _, kv := range os.Environ() {
		if i := strings.IndexByte(kv, '='); i > 0 {
			set(kv[:i], kv[i+1:])
		}
	}
	sandboxBins := strings.Join([]string{
		filepath.Join(dir, ".local", "bin"),
		filepath.Join(dir, ".npm-global", "bin"),
		filepath.Join(dir, ".bun", "bin"),
	}, string(os.PathListSeparator))
	extra := []string{}
	for _, p := range []string{"/opt/homebrew/bin", "/usr/local/bin", filepath.Join(d.RealHome, ".local", "bin"), filepath.Join(d.RealHome, ".bun", "bin")} {
		if st, err := os.Stat(p); err == nil && st.IsDir() && !strings.Contains(base["PATH"], p) {
			extra = append(extra, p)
		}
	}
	path := sandboxBins + string(os.PathListSeparator) + base["PATH"]
	if len(extra) > 0 {
		path += string(os.PathListSeparator) + strings.Join(extra, string(os.PathListSeparator))
	}
	set("PATH", path)
	set("HOME", dir)
	set("npm_config_prefix", filepath.Join(dir, ".npm-global"))
	if _, ok := base["npm_config_cache"]; !ok && d.RealHome != "" {
		set("npm_config_cache", filepath.Join(d.RealHome, ".npm"))
	}
	set("FOUNTAIN_SANDBOX_DIR", dir)
	for _, kv := range pairs {
		if len(kv) == 2 {
			set(kv[0], kv[1])
		}
	}
	out := make([]string, 0, len(order))
	for _, k := range order {
		out = append(out, k+"="+base[k])
	}
	return out
}

func (d *Daemon) exec(req Request) (map[string]any, func(), error) {
	dir, err := d.existingDir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	ctx := context.Background()
	if req.TimeoutMS != nil && *req.TimeoutMS > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(*req.TimeoutMS)*time.Millisecond)
		defer cancel()
	}
	cmd := d.command(ctx, dir, req)
	var out []byte
	var runErr error
	if req.StderrToStdout {
		out, runErr = cmd.CombinedOutput()
	} else {
		out, runErr = cmd.Output()
	}
	code := 0
	if runErr != nil {
		var exitErr *exec.ExitError
		switch {
		case errors.As(runErr, &exitErr):
			code = exitErr.ExitCode()
			if code < 0 {
				code = 137 // killed (timeout)
			}
		case errors.Is(ctx.Err(), context.DeadlineExceeded):
			code = 124
			out = append(out, []byte("\nfountain runner: command timed out\n")...)
		default:
			// Could not start at all (not found, not executable): data, not a
			// raise — the contract's "nonzero exit is readable".
			code = 127
			out = append(out, []byte(runErr.Error()+"\n")...)
		}
	}
	return map[string]any{
		"output": base64.StdEncoding.EncodeToString(out),
		"code":   code,
	}, nil, nil
}

// ── sessions ─────────────────────────────────────────────────────────────────

func (d *Daemon) spawn(req Request, emit Emitter) (map[string]any, func(), error) {
	dir, err := d.existingDir(req.Name)
	if err != nil {
		return nil, nil, err
	}
	d.mu.Lock()
	d.seq++
	id := fmt.Sprintf("s-%d-%d", time.Now().Unix(), d.seq)
	d.mu.Unlock()

	cmd := d.command(context.Background(), dir, req)
	s, err := startSession(id, req.Name, cmd, req.Stdin, emit, d.Log)
	if err != nil {
		// Never a raise: a command that cannot start is a session that exited
		// 127 with the reason on stdout, so the owner reads it like any other
		// failed process.
		s = failedSession(id, req.Name, req.Cmd, err, emit)
	}
	d.mu.Lock()
	d.sessions[id] = s
	d.pruneLocked(req.Name)
	d.mu.Unlock()

	reqID := req.ID
	after := func() { s.attach(reqID) }
	return map[string]any{"session_id": id}, after, nil
}

// pruneLocked bounds the finished sessions retained per sandbox for replay.
func (d *Daemon) pruneLocked(sandbox string) {
	const keep = 100
	var finished []*Session
	for _, s := range d.sessions {
		if s.sandbox == sandbox && s.exited() {
			finished = append(finished, s)
		}
	}
	if len(finished) <= keep {
		return
	}
	sort.Slice(finished, func(i, j int) bool { return finished[i].createdAt.Before(finished[j].createdAt) })
	for _, s := range finished[:len(finished)-keep] {
		delete(d.sessions, s.id)
	}
}

func (d *Daemon) session(id string) (*Session, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	s, ok := d.sessions[id]
	if !ok {
		return nil, notFound("no session " + id)
	}
	return s, nil
}

func (d *Daemon) stdin(req Request) (map[string]any, func(), error) {
	s, err := d.session(req.SessionID)
	if err != nil {
		return nil, nil, err
	}
	data, err := base64.StdEncoding.DecodeString(req.Data)
	if err != nil {
		return nil, nil, invalid("data is not base64")
	}
	if err := s.write(data); err != nil {
		return nil, nil, err
	}
	return map[string]any{}, nil, nil
}

func (d *Daemon) stdinClose(req Request) (map[string]any, func(), error) {
	s, err := d.session(req.SessionID)
	if err != nil {
		return nil, nil, err
	}
	s.closeStdin()
	return map[string]any{}, nil, nil
}

func (d *Daemon) detach(req Request) (map[string]any, func(), error) {
	s, err := d.session(req.SessionID)
	if err != nil {
		// Detaching from something that is gone is fine.
		return map[string]any{}, nil, nil
	}
	s.detach()
	return map[string]any{}, nil, nil
}

func (d *Daemon) listSessions(req Request) (map[string]any, func(), error) {
	if _, err := d.existingDir(req.Name); err != nil {
		return nil, nil, err
	}
	d.mu.Lock()
	var list []*Session
	for _, s := range d.sessions {
		if s.sandbox == req.Name {
			list = append(list, s)
		}
	}
	d.mu.Unlock()
	// Newest first: reattach takes the first session, and the turn in flight
	// is the most recent spawn.
	sort.Slice(list, func(i, j int) bool { return list[i].createdAt.After(list[j].createdAt) })
	out := make([]map[string]any, 0, len(list))
	for _, s := range list {
		out = append(out, s.describe())
	}
	return map[string]any{"sessions": out}, nil, nil
}

func (d *Daemon) attach(req Request, emit Emitter) (map[string]any, func(), error) {
	s, err := d.session(req.SessionID)
	if err != nil {
		return nil, nil, err
	}
	reqID := req.ID
	return map[string]any{"session_id": s.id}, func() { s.attach(reqID) }, nil
}

// stopSessions terminates every live session of a sandbox (suspend/destroy).
func (d *Daemon) stopSessions(sandbox string) {
	d.mu.Lock()
	var live []*Session
	for _, s := range d.sessions {
		if s.sandbox == sandbox && !s.exited() {
			live = append(live, s)
		}
	}
	d.mu.Unlock()
	for _, s := range live {
		s.terminate(5 * time.Second)
	}
}

// StopAll terminates every live session (daemon shutdown).
func (d *Daemon) StopAll() {
	d.mu.Lock()
	var live []*Session
	for _, s := range d.sessions {
		if !s.exited() {
			live = append(live, s)
		}
	}
	d.mu.Unlock()
	for _, s := range live {
		s.terminate(3 * time.Second)
	}
}

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
