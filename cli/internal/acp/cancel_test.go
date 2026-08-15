package acp

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"testing"
	"time"
)

func TestCancelInterruptsTheConversation(t *testing.T) {
	api := &fakeAPI{}
	a, _ := promptAgent(t, api)

	a.Notify(context.Background(), "session/cancel", mustJSON(t, map[string]any{"sessionId": "conv-1"}))

	if len(api.interrupted) != 1 || api.interrupted[0] != "conv-1" {
		t.Errorf("interrupted = %v, want [conv-1]", api.interrupted)
	}
}

func TestCancelForAnUnknownSessionInterruptsNothing(t *testing.T) {
	api := &fakeAPI{}
	a, _ := promptAgent(t, api)

	a.Notify(context.Background(), "session/cancel", mustJSON(t, map[string]any{"sessionId": "not-a-session"}))

	if len(api.interrupted) != 0 {
		t.Errorf("interrupted %v for a session that does not exist", api.interrupted)
	}
}

// A cancel that raced the agent finishing is the normal case, not a failure —
// and there is nobody to report it to anyway, since notifications have no
// response.
func TestCancelSurvivesAFailedInterrupt(t *testing.T) {
	api := &fakeAPI{interruptErr: errors.New("http 409: no_turn_running")}
	a, _ := promptAgent(t, api)

	a.Notify(context.Background(), "session/cancel", mustJSON(t, map[string]any{"sessionId": "conv-1"}))

	if len(api.interrupted) != 1 {
		t.Errorf("interrupt was not attempted: %v", api.interrupted)
	}
}

// The one that matters: a cancel has to reach the agent WHILE a prompt is
// blocked, which is only possible because requests dispatch concurrently. This
// drives it through a real Conn — the fake API's Follow blocks until the
// interrupt arrives, exactly as a real turn would sit there until stopped.
func TestCancelReachesAPromptThatIsStillRunning(t *testing.T) {
	interrupted := make(chan struct{})
	api := &fakeAPI{
		ref:           acpAgentRef(),
		convID:        "conv-1",
		onInterrupt:   func() { close(interrupted) },
		followBlock:   interrupted,
		followStarted: make(chan struct{}),
		events:        []Event{stageEvent("turn", "interrupted", `{}`)},
	}

	a := NewAgent(&fakeAuth{available: true}, api, "researcher", "test", discardLogger())
	client := newTestClient(t, a)
	defer client.close()

	// Driven one message at a time, as a client does: each request is sent
	// after the previous one is answered. The cancel is the exception — it is
	// sent while the prompt is deliberately still outstanding, which is the
	// whole point.
	client.request(1, "initialize", map[string]any{"protocolVersion": ProtocolVersion})
	client.request(2, "session/new", map[string]any{})

	client.send(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":` +
		`{"sessionId":"conv-1","prompt":[{"type":"text","text":"go"}]}}`)

	select {
	case <-api.followStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("the turn never started")
	}

	client.send(`{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"conv-1"}}`)

	msg := client.await(3)

	select {
	case <-interrupted:
	default:
		t.Fatal("the turn was never interrupted")
	}

	result, ok := msg["result"].(map[string]any)
	if !ok {
		t.Fatalf("the prompt answered with %v, want a cancelled stop reason", msg)
	}
	if result["stopReason"] != "cancelled" {
		t.Errorf("stopReason = %v, want cancelled", result["stopReason"])
	}
}

// testClient drives a Conn over a pipe, the way an editor does: write a
// request, read until its response arrives. Feeding every line at once instead
// would race a prompt against the `session/new` that creates its session —
// which no client does, because it has nothing to prompt until the session id
// comes back.
type testClient struct {
	t     *testing.T
	in    *io.PipeWriter
	msgs  chan map[string]any
	serve chan error
}

func newTestClient(t *testing.T, a *Agent) *testClient {
	t.Helper()

	inR, inW := io.Pipe()
	outR, outW := io.Pipe()

	conn := NewConn(inR, outW, discardLogger())
	a.SetNotifier(conn)

	c := &testClient{
		t:     t,
		in:    inW,
		msgs:  make(chan map[string]any, 32),
		serve: make(chan error, 1),
	}

	go func() {
		err := conn.Serve(context.Background(), a)
		outW.Close()
		c.serve <- err
	}()

	go func() {
		defer close(c.msgs)
		dec := json.NewDecoder(outR)
		for {
			var m map[string]any
			if err := dec.Decode(&m); err != nil {
				return
			}
			c.msgs <- m
		}
	}()

	return c
}

func (c *testClient) send(line string) {
	c.t.Helper()
	if _, err := io.WriteString(c.in, line+"\n"); err != nil {
		c.t.Fatalf("write: %v", err)
	}
}

// await reads until the response with this id arrives, ignoring notifications.
func (c *testClient) await(id int) map[string]any {
	c.t.Helper()
	for {
		select {
		case msg, ok := <-c.msgs:
			if !ok {
				c.t.Fatalf("connection closed before answering %d", id)
			}
			if msg["id"] == float64(id) {
				return msg
			}
		case <-time.After(5 * time.Second):
			c.t.Fatalf("timed out waiting for a response to %d", id)
		}
	}
}

func (c *testClient) request(id int, method string, params any) map[string]any {
	c.t.Helper()
	c.send(string(mustJSON(c.t, map[string]any{
		"jsonrpc": "2.0", "id": id, "method": method, "params": params,
	})))
	return c.await(id)
}

func (c *testClient) close() {
	c.in.Close()
	select {
	case <-c.serve:
	case <-time.After(5 * time.Second):
		c.t.Error("Serve did not return after stdin closed")
	}
}

func mustJSON(t *testing.T, v any) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return raw
}
