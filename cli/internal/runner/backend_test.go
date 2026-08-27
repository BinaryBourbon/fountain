package runner

import (
	"errors"
	"log/slog"
	"os"
	"testing"
)

// recordingBackend answers every op by naming itself, so the routing can be
// checked without a filesystem.
type recordingBackend struct {
	calls    []string
	gotEmit  Emitter
	stopped  bool
	lastName string
}

func (b *recordingBackend) note(op string, req Request) (map[string]any, func(), error) {
	b.calls = append(b.calls, op)
	b.lastName = req.Name
	return map[string]any{"called": op}, nil, nil
}

func (b *recordingBackend) Create(req Request) (map[string]any, func(), error) {
	return b.note("Create", req)
}
func (b *recordingBackend) Get(req Request) (map[string]any, func(), error) {
	return b.note("Get", req)
}
func (b *recordingBackend) Destroy(req Request) (map[string]any, func(), error) {
	return b.note("Destroy", req)
}
func (b *recordingBackend) List() (map[string]any, func(), error) {
	return b.note("List", Request{})
}
func (b *recordingBackend) Suspend(req Request) (map[string]any, func(), error) {
	return b.note("Suspend", req)
}
func (b *recordingBackend) Resume(req Request) (map[string]any, func(), error) {
	return b.note("Resume", req)
}
func (b *recordingBackend) WriteFile(req Request) (map[string]any, func(), error) {
	return b.note("WriteFile", req)
}
func (b *recordingBackend) Exec(req Request) (map[string]any, func(), error) {
	return b.note("Exec", req)
}
func (b *recordingBackend) Spawn(req Request, emit Emitter) (map[string]any, func(), error) {
	b.gotEmit = emit
	return b.note("Spawn", req)
}
func (b *recordingBackend) Stdin(req Request) (map[string]any, func(), error) {
	return b.note("Stdin", req)
}
func (b *recordingBackend) StdinClose(req Request) (map[string]any, func(), error) {
	return b.note("StdinClose", req)
}
func (b *recordingBackend) Detach(req Request) (map[string]any, func(), error) {
	return b.note("Detach", req)
}
func (b *recordingBackend) ListSessions(req Request) (map[string]any, func(), error) {
	return b.note("ListSessions", req)
}
func (b *recordingBackend) Attach(req Request, emit Emitter) (map[string]any, func(), error) {
	b.gotEmit = emit
	return b.note("Attach", req)
}
func (b *recordingBackend) StopAll() { b.stopped = true }

// Every op in the wire protocol reaches exactly one Backend method. The
// table is the protocol: an op added to Fountain.Runners.Connection without
// a case here answers not_supported, which is why the default is tested too.
func TestHandleRoutesEveryOpToTheBackend(t *testing.T) {
	ops := []struct{ op, method string }{
		{"create", "Create"},
		{"get", "Get"},
		{"destroy", "Destroy"},
		{"list", "List"},
		{"suspend", "Suspend"},
		{"resume", "Resume"},
		{"write_file", "WriteFile"},
		{"exec", "Exec"},
		{"spawn", "Spawn"},
		{"stdin", "Stdin"},
		{"stdin_close", "StdinClose"},
		{"detach", "Detach"},
		{"list_sessions", "ListSessions"},
		{"attach", "Attach"},
	}
	for _, tc := range ops {
		b := &recordingBackend{}
		d := NewWithBackend(b, slog.New(slog.NewTextHandler(os.Stderr, nil)))
		rec := newRecorder()
		result, _, err := d.Handle(Request{Op: tc.op, Name: "runner-x-1"}, rec)
		if err != nil {
			t.Fatalf("%s: %v", tc.op, err)
		}
		if len(b.calls) != 1 || b.calls[0] != tc.method {
			t.Fatalf("op %q called %v, want [%s]", tc.op, b.calls, tc.method)
		}
		if result["called"] != tc.method {
			t.Fatalf("op %q returned %v", tc.op, result)
		}
	}
}

// spawn and attach are the two ops that stream, so they are the two that
// must be handed the emitter the reply is going out on.
func TestStreamingOpsReceiveTheEmitter(t *testing.T) {
	for _, op := range []string{"spawn", "attach"} {
		b := &recordingBackend{}
		d := NewWithBackend(b, slog.New(slog.NewTextHandler(os.Stderr, nil)))
		rec := newRecorder()
		if _, _, err := d.Handle(Request{Op: op, Name: "runner-x-1"}, rec); err != nil {
			t.Fatal(err)
		}
		if b.gotEmit != Emitter(rec) {
			t.Fatalf("%s did not receive the request's emitter", op)
		}
	}
}

func TestUnknownOpIsNotSupported(t *testing.T) {
	b := &recordingBackend{}
	d := NewWithBackend(b, slog.New(slog.NewTextHandler(os.Stderr, nil)))
	_, _, err := d.Handle(Request{Op: "teleport"}, newRecorder())
	var op *OpError
	if err == nil {
		t.Fatal("want an error")
	}
	if !errors.As(err, &op) || op.Code != "not_supported" {
		t.Fatalf("err = %v", err)
	}
	if len(b.calls) != 0 {
		t.Fatalf("backend was called: %v", b.calls)
	}
}

func TestStopAllReachesTheBackend(t *testing.T) {
	b := &recordingBackend{}
	NewWithBackend(b, slog.New(slog.NewTextHandler(os.Stderr, nil))).StopAll()
	if !b.stopped {
		t.Fatal("StopAll did not reach the backend")
	}
}
