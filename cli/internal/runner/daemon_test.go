package runner

import (
	"encoding/base64"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// recorder collects emitted frames and lets tests wait for them.
type recorder struct {
	mu     sync.Mutex
	frames []Frame
	notify chan struct{}
}

func newRecorder() *recorder { return &recorder{notify: make(chan struct{}, 1024)} }

func (r *recorder) Emit(f Frame) {
	r.mu.Lock()
	r.frames = append(r.frames, f)
	r.mu.Unlock()
	select {
	case r.notify <- struct{}{}:
	default:
	}
}

// waitFor blocks until pred holds over the frames or the deadline passes.
func (r *recorder) waitFor(t *testing.T, pred func([]Frame) bool) []Frame {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		r.mu.Lock()
		snap := append([]Frame(nil), r.frames...)
		r.mu.Unlock()
		if pred(snap) {
			return snap
		}
		select {
		case <-r.notify:
		case <-deadline:
			t.Fatalf("timed out waiting for frames; have %v", snap)
		}
	}
}

func hasExit(frames []Frame, session string) bool {
	for _, f := range frames {
		if f["stream"] == "exit" && f["session_id"] == session {
			return true
		}
	}
	return false
}

func stdoutOf(frames []Frame, session string, replay bool) string {
	var b strings.Builder
	for _, f := range frames {
		if f["stream"] != "stdout" || f["session_id"] != session {
			continue
		}
		_, isReplay := f["replay_for"]
		if isReplay != replay {
			continue
		}
		data, _ := base64.StdEncoding.DecodeString(f["data"].(string))
		b.Write(data)
	}
	return b.String()
}

func newDaemon(t *testing.T) *Daemon {
	t.Helper()
	d, err := New(t.TempDir(), slog.New(slog.NewTextHandler(os.Stderr, nil)))
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func do(t *testing.T, d *Daemon, req Request, emit Emitter) map[string]any {
	t.Helper()
	result, _, err := d.Handle(req, emit)
	if err != nil {
		t.Fatalf("%s: unexpected error: %v", req.Op, err)
	}
	return result
}

func TestCreateGetDestroy(t *testing.T) {
	d := newDaemon(t)
	rec := newRecorder()

	do(t, d, Request{Op: "create", Name: "runner-a-1"}, rec)
	do(t, d, Request{Op: "create", Name: "runner-a-1"}, rec) // adopt
	got := do(t, d, Request{Op: "get", Name: "runner-a-1"}, rec)
	if got["status"] != "running" {
		t.Fatalf("status = %v", got["status"])
	}
	list := do(t, d, Request{Op: "list"}, rec)
	if names := list["names"].([]string); len(names) != 1 || names[0] != "runner-a-1" {
		t.Fatalf("names = %v", names)
	}

	if _, _, err := d.Handle(Request{Op: "get", Name: "runner-none"}, rec); err == nil || err.(*OpError).Code != "not_found" {
		t.Fatalf("get missing = %v", err)
	}
	do(t, d, Request{Op: "destroy", Name: "runner-none"}, rec) // already gone
	do(t, d, Request{Op: "destroy", Name: "runner-a-1"}, rec)
	if _, _, err := d.Handle(Request{Op: "get", Name: "runner-a-1"}, rec); err == nil {
		t.Fatal("destroyed sandbox still gettable")
	}
	if _, _, err := d.Handle(Request{Op: "create", Name: "../escape"}, rec); err == nil {
		t.Fatal("path traversal accepted")
	}
}

func TestSuspendResume(t *testing.T) {
	d := newDaemon(t)
	rec := newRecorder()
	do(t, d, Request{Op: "create", Name: "sb"}, rec)
	do(t, d, Request{Op: "suspend", Name: "sb"}, rec)
	if got := do(t, d, Request{Op: "get", Name: "sb"}, rec); got["status"] != "suspended" {
		t.Fatalf("status after suspend = %v", got["status"])
	}
	do(t, d, Request{Op: "resume", Name: "sb"}, rec)
	if got := do(t, d, Request{Op: "get", Name: "sb"}, rec); got["status"] != "running" {
		t.Fatalf("status after resume = %v", got["status"])
	}
}

func TestWriteFileMapsSpriteHome(t *testing.T) {
	d := newDaemon(t)
	rec := newRecorder()
	do(t, d, Request{Op: "create", Name: "sb"}, rec)
	mode := 0o600
	do(t, d, Request{
		Op: "write_file", Name: "sb", Path: "/home/sprite/.env",
		Data: base64.StdEncoding.EncodeToString([]byte("A=1\n")), Mode: &mode,
	}, rec)
	target := filepath.Join(d.Root, "sb", ".env")
	body, err := os.ReadFile(target)
	if err != nil || string(body) != "A=1\n" {
		t.Fatalf("file not written inside the sandbox: %v %q", err, body)
	}
	if st, _ := os.Stat(target); st.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", st.Mode().Perm())
	}
	// Parent directories are created; relative paths are sandbox-relative.
	do(t, d, Request{Op: "write_file", Name: "sb", Path: ".claude/skills/x/SKILL.md",
		Data: base64.StdEncoding.EncodeToString([]byte("# x"))}, rec)
	if _, err := os.Stat(filepath.Join(d.Root, "sb", ".claude", "skills", "x", "SKILL.md")); err != nil {
		t.Fatal(err)
	}
}

func TestExec(t *testing.T) {
	d := newDaemon(t)
	rec := newRecorder()
	do(t, d, Request{Op: "create", Name: "sb"}, rec)

	got := do(t, d, Request{Op: "exec", Name: "sb", Cmd: "sh", Args: []string{"-c", "echo hello; echo err >&2"}}, rec)
	out, _ := base64.StdEncoding.DecodeString(got["output"].(string))
	if got["code"] != 0 || string(out) != "hello\n" {
		t.Fatalf("exec = %v %q", got["code"], out)
	}

	got = do(t, d, Request{Op: "exec", Name: "sb", Cmd: "sh", Args: []string{"-c", "echo oops >&2; exit 3"}, StderrToStdout: true}, rec)
	out, _ = base64.StdEncoding.DecodeString(got["output"].(string))
	if got["code"] != 3 || string(out) != "oops\n" {
		t.Fatalf("exec fail = %v %q", got["code"], out)
	}

	// HOME is the sandbox and /home/sprite maps into it, in args too.
	got = do(t, d, Request{Op: "exec", Name: "sb", Cmd: "sh", Args: []string{"-c", "echo $HOME; echo /home/sprite/x; pwd -P"}}, rec)
	out, _ = base64.StdEncoding.DecodeString(got["output"].(string))
	sb := filepath.Join(d.Root, "sb")
	realSb, _ := filepath.EvalSymlinks(sb) // macOS: /var → /private/var
	want := sb + "\n" + sb + "/x\n" + realSb + "\n"
	if string(out) != want {
		t.Fatalf("env mapping: got %q want %q", out, want)
	}

	// Request env wins; a missing command is data (127), not an error.
	got = do(t, d, Request{Op: "exec", Name: "sb", Cmd: "sh", Args: []string{"-c", "echo $FOO"}, Env: [][]string{{"FOO", "bar"}}}, rec)
	out, _ = base64.StdEncoding.DecodeString(got["output"].(string))
	if string(out) != "bar\n" {
		t.Fatalf("env = %q", out)
	}
	got = do(t, d, Request{Op: "exec", Name: "sb", Cmd: "definitely-not-a-command-xyz"}, rec)
	if got["code"] != 127 {
		t.Fatalf("missing command code = %v", got["code"])
	}

	// A timeout is a code too.
	ms := 200
	got = do(t, d, Request{Op: "exec", Name: "sb", Cmd: "sleep", Args: []string{"5"}, TimeoutMS: &ms}, rec)
	if got["code"] == 0 {
		t.Fatalf("timed out exec reported success")
	}
}

func TestSpawnStreamsAfterReplyAndReplaysOnAttach(t *testing.T) {
	d := newDaemon(t)
	rec := newRecorder()
	do(t, d, Request{Op: "create", Name: "sb"}, rec)

	result, after, err := d.Handle(Request{ID: 7, Op: "spawn", Name: "sb", Cmd: "sh",
		Args: []string{"-c", "echo ready; while read l; do echo echo:$l; done"}, Stdin: true}, rec)
	if err != nil {
		t.Fatal(err)
	}
	sid := result["session_id"].(string)
	// Nothing streams before `after` (the reply) — frames may be journaled.
	time.Sleep(100 * time.Millisecond)
	if n := len(rec.frames); n != 0 {
		t.Fatalf("streamed %d frames before the reply", n)
	}
	after()
	rec.waitFor(t, func(fs []Frame) bool {
		return strings.Contains(stdoutOf(fs, sid, true)+stdoutOf(fs, sid, false), "ready")
	})

	// stdin round-trips.
	do(t, d, Request{Op: "stdin", SessionID: sid, Data: base64.StdEncoding.EncodeToString([]byte("ping\n"))}, rec)
	rec.waitFor(t, func(fs []Frame) bool { return strings.Contains(stdoutOf(fs, sid, false), "echo:ping") })

	// A second attacher gets everything from byte zero, tagged for it only.
	_, after2, err := d.Handle(Request{ID: 9, Op: "attach", SessionID: sid}, rec)
	if err != nil {
		t.Fatal(err)
	}
	after2()
	frames := rec.waitFor(t, func(fs []Frame) bool {
		return strings.Contains(stdoutOf(fs, sid, true), "echo:ping")
	})
	replayFor9 := ""
	for _, f := range frames {
		if f["replay_for"] == 9 && f["stream"] == "stdout" {
			data, _ := base64.StdEncoding.DecodeString(f["data"].(string))
			replayFor9 += string(data)
		}
	}
	if replayFor9 != "ready\necho:ping\n" {
		t.Fatalf("replay for attacher = %q", replayFor9)
	}

	// EOF ends it with the real exit code; a late write is command_exited.
	do(t, d, Request{Op: "stdin_close", SessionID: sid}, rec)
	rec.waitFor(t, func(fs []Frame) bool { return hasExit(fs, sid) })
	if _, _, err := d.Handle(Request{Op: "stdin", SessionID: sid, Data: base64.StdEncoding.EncodeToString([]byte("late"))}, rec); err == nil || err.(*OpError).Code != "command_exited" {
		t.Fatalf("late write = %v", err)
	}

	// Sessions list newest first and describe themselves.
	sessions := do(t, d, Request{Op: "list_sessions", Name: "sb"}, rec)["sessions"].([]map[string]any)
	if len(sessions) != 1 || sessions[0]["id"] != sid || sessions[0]["exit_code"] != 0 {
		t.Fatalf("sessions = %v", sessions)
	}
}

func TestSpawnExitCodeAndFailedStart(t *testing.T) {
	d := newDaemon(t)
	rec := newRecorder()
	do(t, d, Request{Op: "create", Name: "sb"}, rec)

	result, after, _ := d.Handle(Request{ID: 1, Op: "spawn", Name: "sb", Cmd: "sh", Args: []string{"-c", "echo partial; exit 4"}}, rec)
	sid := result["session_id"].(string)
	after()
	frames := rec.waitFor(t, func(fs []Frame) bool { return hasExit(fs, sid) })
	for _, f := range frames {
		if f["stream"] == "exit" && f["session_id"] == sid && f["code"] != 4 {
			t.Fatalf("exit code = %v", f["code"])
		}
	}

	rec2 := newRecorder()
	result, after, err := d.Handle(Request{ID: 2, Op: "spawn", Name: "sb", Cmd: "no-such-binary-xyz"}, rec2)
	if err != nil {
		t.Fatalf("a command that cannot start must still be a session: %v", err)
	}
	after()
	sid = result["session_id"].(string)
	frames = rec2.waitFor(t, func(fs []Frame) bool { return hasExit(fs, sid) })
	for _, f := range frames {
		if f["stream"] == "exit" && f["code"] != 127 {
			t.Fatalf("failed start exit code = %v", f["code"])
		}
	}
	if !strings.Contains(stdoutOf(frames, sid, true), "fountain runner:") {
		t.Fatalf("failed start reason missing: %v", frames)
	}
}

func TestSuspendStopsSessions(t *testing.T) {
	d := newDaemon(t)
	rec := newRecorder()
	do(t, d, Request{Op: "create", Name: "sb"}, rec)
	result, after, _ := d.Handle(Request{ID: 1, Op: "spawn", Name: "sb", Cmd: "sleep", Args: []string{"30"}}, rec)
	after()
	sid := result["session_id"].(string)
	do(t, d, Request{Op: "suspend", Name: "sb"}, rec)
	rec.waitFor(t, func(fs []Frame) bool { return hasExit(fs, sid) })
}

func TestSpawnResolvesCommandOnSandboxPath(t *testing.T) {
	// A CLI installed by provisioning into <sandbox>/.local/bin must be found
	// even though the daemon's own PATH knows nothing about it.
	d := newDaemon(t)
	rec := newRecorder()
	do(t, d, Request{Op: "create", Name: "sb"}, rec)
	bin := filepath.Join(d.Root, "sb", ".local", "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\necho from-sandbox-bin\n"
	if err := os.WriteFile(filepath.Join(bin, "fake-agent-acp"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	got := do(t, d, Request{Op: "exec", Name: "sb", Cmd: "fake-agent-acp"}, rec)
	out, _ := base64.StdEncoding.DecodeString(got["output"].(string))
	if got["code"] != 0 || string(out) != "from-sandbox-bin\n" {
		t.Fatalf("exec via sandbox PATH = %v %q", got["code"], out)
	}
	result, after, _ := d.Handle(Request{ID: 1, Op: "spawn", Name: "sb", Cmd: "fake-agent-acp"}, rec)
	after()
	sid := result["session_id"].(string)
	frames := rec.waitFor(t, func(fs []Frame) bool { return hasExit(fs, sid) })
	if !strings.Contains(stdoutOf(frames, sid, true)+stdoutOf(frames, sid, false), "from-sandbox-bin") {
		t.Fatalf("spawn via sandbox PATH: %v", frames)
	}
}

func TestMapPath(t *testing.T) {
	cases := map[string]string{
		"/home/sprite":      "/sb",
		"/home/sprite/.env": "/sb/.env",
		"~/x":               "/sb/x",
		"rel/path":          "/sb/rel/path",
		"/tmp/other":        "/tmp/other",
		"":                  "/sb",
	}
	for in, want := range cases {
		if got := mapPath("/sb", in); got != want {
			t.Errorf("mapPath(%q) = %q, want %q", in, got, want)
		}
	}
	if got := mapArg("/sb", "bin=/home/sprite/.local/bin/x && cd /home/sprite"); got != "bin=/sb/.local/bin/x && cd /sb" {
		t.Errorf("mapArg = %q", got)
	}
}

func TestReplyShapes(t *testing.T) {
	ok := Reply(3, map[string]any{"a": 1}, nil)
	if ok["ok"] != true || ok["id"] != 3 {
		t.Fatalf("ok reply = %v", ok)
	}
	bad := Reply(4, nil, notFound("x"))
	if bad["ok"] != false || bad["error"] != "not_found" || bad["detail"] != "x" {
		t.Fatalf("error reply = %v", bad)
	}
	if s := string(Marshal(bad)); !strings.Contains(s, `"error":"not_found"`) {
		t.Fatalf("marshal = %s", s)
	}
}
