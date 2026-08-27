package runner

import (
	"bufio"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeVM is the Firecracker end of the vsock: a unix socket that answers
// "CONNECT <port>" with "OK <port>" and then hands the stream to a real
// guest agent. Everything above it in these tests — the link, the framing,
// the ordering, the Process backend answering inside the "VM" — is the
// production path.
type fakeVM struct {
	uds     string
	guest   *Daemon
	home    string
	ln      net.Listener
	handler *chanListener

	mu    sync.Mutex
	conns []net.Conn
}

// chanListener feeds already-handshaken connections to ServeGuest.
type chanListener struct {
	ch   chan io.ReadWriteCloser
	done chan struct{}
	once sync.Once
}

func (l *chanListener) Accept() (io.ReadWriteCloser, error) {
	select {
	case c := <-l.ch:
		return c, nil
	case <-l.done:
		return nil, io.EOF
	}
}

func (l *chanListener) Close() error {
	l.once.Do(func() { close(l.done) })
	return nil
}

func startFakeVM(t *testing.T) *fakeVM {
	t.Helper()
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))

	// A short directory: a unix socket path is capped near 104 bytes, and
	// t.TempDir() plus a long test name overruns it.
	dir, err := os.MkdirTemp("", "fcvm")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })

	guestRoot := filepath.Join(dir, "home")
	home := filepath.Join(guestRoot, guestSandbox)
	if err := os.MkdirAll(home, 0o700); err != nil {
		t.Fatal(err)
	}
	backend, err := NewProcess(guestRoot, log)
	if err != nil {
		t.Fatal(err)
	}
	guest := NewWithBackend(backend, log)

	uds := filepath.Join(dir, "v.sock")
	ln, err := net.Listen("unix", uds)
	if err != nil {
		t.Fatal(err)
	}
	vm := &fakeVM{
		uds:     uds,
		guest:   guest,
		home:    home,
		ln:      ln,
		handler: &chanListener{ch: make(chan io.ReadWriteCloser), done: make(chan struct{})},
	}

	ctx, cancel := context.WithCancel(context.Background())
	go func() { _ = ServeGuest(ctx, vm.handler, guest, log) }()
	go vm.acceptLoop()

	t.Cleanup(func() {
		cancel()
		_ = ln.Close()
		vm.cutLink()
		guest.StopAll()
	})
	return vm
}

// acceptLoop performs Firecracker's host-side handshake.
func (v *fakeVM) acceptLoop() {
	for {
		conn, err := v.ln.Accept()
		if err != nil {
			return
		}
		r := bufio.NewReader(conn)
		line, err := r.ReadString('\n')
		if err != nil || !strings.HasPrefix(line, "CONNECT ") {
			_ = conn.Close()
			continue
		}
		port := strings.TrimSpace(strings.TrimPrefix(line, "CONNECT "))
		if _, err := fmt.Fprintf(conn, "OK %s\n", port); err != nil {
			_ = conn.Close()
			continue
		}
		v.mu.Lock()
		v.conns = append(v.conns, conn)
		v.mu.Unlock()
		// The bufio.Reader may already hold buffered bytes, so the guest
		// gets a stream that reads through it.
		v.handler.ch <- &bufferedConn{Reader: r, Conn: conn}
	}
}

// cutLink drops every live host connection, which is what a microVM going
// away looks like from the daemon's side.
func (v *fakeVM) cutLink() {
	v.mu.Lock()
	conns := v.conns
	v.conns = nil
	v.mu.Unlock()
	for _, c := range conns {
		_ = c.Close()
	}
}

type bufferedConn struct {
	*bufio.Reader
	net.Conn
}

func (c *bufferedConn) Read(p []byte) (int, error) { return c.Reader.Read(p) }
func (c *bufferedConn) Close() error               { return c.Conn.Close() }

func testLink(t *testing.T, vm *fakeVM) *guestLink {
	t.Helper()
	link := newGuestLink(vm.uds, slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})))
	t.Cleanup(link.close)
	return link
}

// allStdout is every stdout byte of a session, replayed or live. Which of
// the two a given chunk arrives as is a race the guest wins or loses on
// timing — output produced before the attach is replayed and output after it
// is live — so a test that pinned one would be pinning the scheduler. What
// the contract promises is the bytes, in order, after the reply.
func allStdout(frames []Frame, session string) string {
	var b strings.Builder
	for _, f := range frames {
		if f["stream"] != "stdout" || f["session_id"] != session {
			continue
		}
		data, _ := base64.StdEncoding.DecodeString(f["data"].(string))
		b.Write(data)
	}
	return b.String()
}

// exitCodeOf reads a session's exit code. Frames the guest sent arrive as
// JSON numbers and frames the host synthesised are Go ints; both marshal
// identically on the way to Fountain, so both are accepted here.
func exitCodeOf(t *testing.T, frames []Frame, session string) int {
	t.Helper()
	for _, f := range frames {
		if f["stream"] != "exit" || f["session_id"] != session {
			continue
		}
		switch code := f["code"].(type) {
		case float64:
			return int(code)
		case int:
			return code
		default:
			t.Fatalf("exit code has type %T", f["code"])
		}
	}
	t.Fatalf("no exit frame for %s", session)
	return 0
}

func call(t *testing.T, link *guestLink, req Request, emit Emitter) (map[string]any, func()) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	result, after, err := link.call(ctx, req, emit)
	if err != nil {
		t.Fatalf("%s: %v", req.Op, err)
	}
	return result, after
}

// The handshake is the whole host-side vsock story, so it is worth pinning
// that a socket which does not answer it is reported as the rootfs problem
// it is rather than as a timeout.
func TestDialGuestRejectsASocketThatDoesNotSpeakVsock(t *testing.T) {
	dir, err := os.MkdirTemp("", "fcbad")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	uds := filepath.Join(dir, "v.sock")
	ln, err := net.Listen("unix", uds)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ln.Close() }()
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		_, _ = conn.Write([]byte("NO\n"))
		_ = conn.Close()
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, _, err := dialGuest(ctx, uds); err == nil || !strings.Contains(err.Error(), "runner-guest") {
		t.Fatalf("err = %v, want one naming the guest agent", err)
	}
}

func TestGuestAgentAnswersPing(t *testing.T) {
	vm := startFakeVM(t)
	link := testLink(t, vm)
	result, _ := call(t, link, Request{ID: link.probeID(), Op: "ping"}, nil)
	if result["agent"] != "fountain runner-guest" {
		t.Fatalf("ping = %v", result)
	}
}

// An exec crosses the link, runs in the guest's Process backend, and comes
// back as output plus a code. A nonzero exit is data, not an error.
func TestExecRoundTripsThroughTheGuest(t *testing.T) {
	vm := startFakeVM(t)
	link := testLink(t, vm)

	result, _ := call(t, link, Request{ID: 1, Op: "exec", Name: guestSandbox,
		Cmd: "sh", Args: []string{"-c", "echo hello; exit 3"}}, nil)
	out, err := base64.StdEncoding.DecodeString(result["output"].(string))
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(out)) != "hello" {
		t.Fatalf("output = %q", out)
	}
	if result["code"].(float64) != 3 {
		t.Fatalf("code = %v", result["code"])
	}
}

// The guest chooses the error code; the link must carry it rather than
// flattening everything into a provider failure, because Fountain's retry
// classification and its not-found handling both read that code.
func TestGuestErrorCodesSurviveTheLink(t *testing.T) {
	vm := startFakeVM(t)
	link := testLink(t, vm)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, _, err := link.call(ctx, Request{ID: 1, Op: "exec", Name: "not-a-sandbox", Cmd: "true"}, nil)
	var op *OpError
	if !errors.As(err, &op) || op.Code != "not_found" {
		t.Fatalf("err = %v, want not_found", err)
	}
}

// A file written through the link lands in the guest's /home/sprite, with
// no path rewriting on either side.
func TestWriteFileLandsInTheGuestHome(t *testing.T) {
	vm := startFakeVM(t)
	link := testLink(t, vm)

	mode := 0o600
	call(t, link, Request{ID: 1, Op: "write_file", Name: guestSandbox,
		Path: "/home/sprite/.env", Data: base64.StdEncoding.EncodeToString([]byte("TOKEN=x")), Mode: &mode}, nil)

	got, err := os.ReadFile(filepath.Join(vm.home, ".env"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "TOKEN=x" {
		t.Fatalf("file = %q", got)
	}
}

// The ordering rule Fountain depends on: a spawn's replay must not reach the
// wire before the spawn's own reply. The host writes that reply only after
// call() returns, so anything the guest sends in between has to be held.
func TestSpawnReplayIsHeldUntilAfterTheReply(t *testing.T) {
	vm := startFakeVM(t)
	link := testLink(t, vm)
	rec := newRecorder()

	result, after := call(t, link, Request{ID: 7, Op: "spawn", Name: guestSandbox,
		Cmd: "sh", Args: []string{"-c", "echo streamed; exit 0"}}, rec)
	sid := result["session_id"].(string)

	// Give the guest time to finish the command and push its replay, so
	// this asserts the gate rather than a race the test happened to win.
	time.Sleep(300 * time.Millisecond)
	rec.mu.Lock()
	early := len(rec.frames)
	rec.mu.Unlock()
	if early != 0 {
		t.Fatalf("%d frames reached the wire before the reply", early)
	}

	after()
	frames := rec.waitFor(t, func(f []Frame) bool { return hasExit(f, sid) })
	if got := allStdout(frames, sid); strings.TrimSpace(got) != "streamed" {
		t.Fatalf("stdout after the reply = %q", got)
	}
}

// stdin has to be total across the link too: a write to a command that has
// already exited is command_exited, never a hang and never a crash.
func TestStdinTotalityAcrossTheLink(t *testing.T) {
	vm := startFakeVM(t)
	link := testLink(t, vm)
	rec := newRecorder()

	result, after := call(t, link, Request{ID: 1, Op: "spawn", Name: guestSandbox,
		Cmd: "sh", Args: []string{"-c", "cat; exit 7"}, Stdin: true}, rec)
	sid := result["session_id"].(string)
	after()

	call(t, link, Request{ID: 2, Op: "stdin", SessionID: sid,
		Data: base64.StdEncoding.EncodeToString([]byte("ping\n"))}, nil)
	call(t, link, Request{ID: 3, Op: "stdin_close", SessionID: sid}, nil)

	frames := rec.waitFor(t, func(f []Frame) bool { return hasExit(f, sid) })
	if got := allStdout(frames, sid); !strings.Contains(got, "ping") {
		t.Fatalf("stdout = %q", got)
	}
	if code := exitCodeOf(t, frames, sid); code != 7 {
		t.Fatalf("exit = %d, want 7", code)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, _, err := link.call(ctx, Request{ID: 4, Op: "stdin", SessionID: sid,
		Data: base64.StdEncoding.EncodeToString([]byte("late"))}, nil)
	var op *OpError
	if !errors.As(err, &op) || op.Code != "command_exited" {
		t.Fatalf("late write = %v, want command_exited", err)
	}
}

// A microVM that dies mid-turn must not read as a command that succeeded.
// Fountain treats a stream that ends without an exit frame as exit 0, so the
// link owes every live session a terminal frame when it drops.
func TestADroppedLinkEndsLiveSessionsRatherThanGoingQuiet(t *testing.T) {
	vm := startFakeVM(t)
	link := testLink(t, vm)
	rec := newRecorder()

	result, after := call(t, link, Request{ID: 1, Op: "spawn", Name: guestSandbox,
		Cmd: "sh", Args: []string{"-c", "echo up; sleep 30"}, Stdin: true}, rec)
	sid := result["session_id"].(string)
	after()
	rec.waitFor(t, func(f []Frame) bool { return strings.Contains(allStdout(f, sid), "up") })

	vm.cutLink()

	frames := rec.waitFor(t, func(f []Frame) bool { return hasExit(f, sid) })
	if code := exitCodeOf(t, frames, sid); code != 137 {
		t.Fatalf("exit = %d, want 137", code)
	}
}

// A pending call when the link drops is transient, not a permanent refusal:
// the VM may be coming back, and unavailable is what makes Fountain retry.
func TestAPendingCallFailsTransientlyWhenTheLinkDrops(t *testing.T) {
	vm := startFakeVM(t)
	link := testLink(t, vm)

	// Bring the link up first, so the drop lands on an established one.
	call(t, link, Request{ID: link.probeID(), Op: "ping"}, nil)

	done := make(chan error, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		_, _, err := link.call(ctx, Request{ID: 1, Op: "exec", Name: guestSandbox,
			Cmd: "sh", Args: []string{"-c", "sleep 30"}}, nil)
		done <- err
	}()
	time.Sleep(200 * time.Millisecond)
	vm.cutLink()

	select {
	case err := <-done:
		var op *OpError
		if errors.As(err, &op) && op.Code != "unavailable" {
			t.Fatalf("err = %v, want unavailable", err)
		}
		if err == nil {
			t.Fatal("want an error")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the pending call never came back")
	}
}
