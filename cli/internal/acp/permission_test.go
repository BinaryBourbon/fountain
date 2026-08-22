package acp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"
)

// fakeClient is a notifier that can also carry a request to the editor — what
// *Conn is in production. `answer` decides what the editor says back.
type fakeClient struct {
	fakeNotifier

	mu       sync.Mutex
	asked    []map[string]any
	answer   func(params map[string]any) (json.RawMessage, error)
	askedCh  chan struct{}
	askedOne sync.Once
}

func (c *fakeClient) Request(_ context.Context, method string, params any) (json.RawMessage, error) {
	c.mu.Lock()
	p, _ := params.(map[string]any)
	c.asked = append(c.asked, p)
	answer := c.answer
	c.mu.Unlock()

	c.askedOne.Do(func() {
		if c.askedCh != nil {
			close(c.askedCh)
		}
	})

	if method != "session/request_permission" {
		return nil, fmt.Errorf("unexpected outbound request %q", method)
	}
	if answer == nil {
		return json.RawMessage(`{"outcome":{"outcome":"cancelled"}}`), nil
	}
	return answer(p)
}

func (c *fakeClient) askedWith() []map[string]any {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]map[string]any(nil), c.asked...)
}

func selected(optionID string) func(map[string]any) (json.RawMessage, error) {
	return func(map[string]any) (json.RawMessage, error) {
		return json.RawMessage(`{"outcome":{"outcome":"selected","optionId":"` + optionID + `"}}`), nil
	}
}

// permissionLine is a stored `session/request_permission` as the server writes
// it: a minted request id (#957), the sprite's session id, and the agent's own
// option list.
func permissionLine(requestID string) string {
	return `{"jsonrpc":"2.0","id":"` + requestID + `","method":"session/request_permission","params":{` +
		`"sessionId":"sprite-session",` +
		`"toolCall":{"title":"curl https://example.com","kind":"execute"},` +
		`"options":[` +
		`{"optionId":"allow","kind":"allow_once","name":"Allow Once"},` +
		`{"optionId":"reject","kind":"reject_once","name":"Deny"}]}}`
}

// permissionAgent is promptAgent with a client that can be asked.
func permissionAgent(t *testing.T, api *fakeAPI) (*Agent, *fakeClient) {
	t.Helper()

	api.ref = acpAgentRef()
	if api.convID == "" {
		api.convID = "conv-1"
	}
	a := sessionAgent(t, api, "researcher")
	c := &fakeClient{askedCh: make(chan struct{})}
	a.SetNotifier(c)

	if _, rpcErr := request(t, a, "session/new", map[string]any{}); rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}
	return a, c
}

// waitForAnswers blocks until the API has recorded n answers, or the deadline
// passes. The forwarding runs on its own goroutine so the stream keeps being
// read while the human decides.
func waitForAnswers(t *testing.T, api *fakeAPI, n int) []permissionAnswer {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		got := api.answered()
		if len(got) >= n {
			return got
		}
		if time.Now().After(deadline) {
			t.Fatalf("waited for %d permission answers, got %d", n, len(got))
		}
		time.Sleep(time.Millisecond)
	}
}

func permissionEvents(requestID string) []Event {
	return []Event{
		{Kind: "output", Stream: "acp", Data: permissionLine(requestID)},
		stageEvent("turn", "done", `{"stop_reason":"end_turn"}`),
	}
}

// The whole point of #708: a request that began in the sprite reaches the human
// in front of the editor, and their answer travels back down the same two hops.
func TestAPermissionRequestReachesTheEditorAndTheAnswerGoesBack(t *testing.T) {
	api := &fakeAPI{events: permissionEvents("4.deadbeefdeadbeef")}
	a, client := permissionAgent(t, api)
	client.answer = selected("allow")

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))

	answers := waitForAnswers(t, api, 1)
	if answers[0] != (permissionAnswer{convID: "conv-1", requestID: "4.deadbeefdeadbeef", optionID: "allow"}) {
		t.Errorf("answer = %+v, want the editor's choice posted for this conversation", answers[0])
	}

	asked := client.askedWith()
	if len(asked) != 1 {
		t.Fatalf("asked the editor %d times, want 1", len(asked))
	}
	// The editor knows this conversation by our session id, not the sprite's.
	if asked[0]["sessionId"] != "conv-1" {
		t.Errorf("sessionId = %v, want conv-1", asked[0]["sessionId"])
	}
	// And it gets the agent's own options, verbatim: a client must never be in
	// a position to synthesise one.
	options, _ := asked[0]["options"].([]any)
	if len(options) != 2 {
		t.Fatalf("forwarded %d options, want the agent's own 2", len(options))
	}
}

// A permission request is a question, not an update. Forwarding it as one would
// put something in the transcript that nothing can answer.
func TestAPermissionRequestIsNotForwardedAsAnUpdate(t *testing.T) {
	api := &fakeAPI{events: permissionEvents("4.deadbeefdeadbeef")}
	a, client := permissionAgent(t, api)
	client.answer = selected("allow")

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))
	waitForAnswers(t, api, 1)

	if client.rawCalls != 0 {
		t.Errorf("sent %d notifications for a request, want 0", client.rawCalls)
	}
}

// Fail closed. An editor that errors or disconnects mid-question is the case
// #708 asked to be distinguishable from nobody-attached: it denies now, with an
// option the agent offered, rather than leaving the turn to time out.
func TestAnEditorThatDoesNotAnswerDeniesTheCall(t *testing.T) {
	api := &fakeAPI{events: permissionEvents("4.deadbeefdeadbeef")}
	a, client := permissionAgent(t, api)
	client.answer = func(map[string]any) (json.RawMessage, error) {
		return nil, errors.New("client went away")
	}

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))

	answers := waitForAnswers(t, api, 1)
	if answers[0].optionID != "reject" {
		t.Errorf("optionID = %q, want the agent's own rejection", answers[0].optionID)
	}
}

// The editor's own "no": ACP's cancelled outcome, which is a dismissal rather
// than a choice. Same fail-closed answer.
func TestADismissedPromptDeniesTheCall(t *testing.T) {
	api := &fakeAPI{events: permissionEvents("4.deadbeefdeadbeef")}
	a, client := permissionAgent(t, api)
	client.answer = func(map[string]any) (json.RawMessage, error) {
		return json.RawMessage(`{"outcome":{"outcome":"cancelled"}}`), nil
	}

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))

	answers := waitForAnswers(t, api, 1)
	if answers[0].optionID != "reject" {
		t.Errorf("optionID = %q, want the agent's own rejection", answers[0].optionID)
	}
}

// An id the agent never advertised would at best error server-side and at worst
// name something unrelated, so it is refused here rather than relayed.
func TestAnOptionTheAgentNeverOfferedIsNotRelayed(t *testing.T) {
	api := &fakeAPI{events: permissionEvents("4.deadbeefdeadbeef")}
	a, client := permissionAgent(t, api)
	client.answer = selected("allow_always_forever")

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))

	answers := waitForAnswers(t, api, 1)
	if answers[0].optionID != "reject" {
		t.Errorf("optionID = %q, want the invented option refused and the call denied", answers[0].optionID)
	}
}

// Never synthesise an option. With no rejection on offer there is nothing
// honest to send, so the request is left to the server's timeout — which denies
// it, with the same rule applied one hop down.
func TestWithNoRejectionOnOfferNothingIsSent(t *testing.T) {
	line := `{"jsonrpc":"2.0","id":"7.aaaabbbbccccdddd","method":"session/request_permission","params":{` +
		`"toolCall":{"kind":"execute"},"options":[{"optionId":"allow","kind":"allow_once"}]}}`
	api := &fakeAPI{events: []Event{
		{Kind: "output", Stream: "acp", Data: line},
		stageEvent("turn", "done", `{"stop_reason":"end_turn"}`),
	}}
	a, client := permissionAgent(t, api)
	client.answer = func(map[string]any) (json.RawMessage, error) {
		return nil, errors.New("client went away")
	}

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))

	select {
	case <-client.askedCh:
	case <-time.After(2 * time.Second):
		t.Fatal("the request never reached the editor")
	}
	time.Sleep(20 * time.Millisecond)
	if got := api.answered(); len(got) != 0 {
		t.Errorf("posted %+v, want nothing when the agent offered no way to refuse", got)
	}
}

// Losing the race is the contract (#940): another attached client, the ask
// timeout, or the turn ending may resolve the request first. The adapter must
// not treat that as a failure.
func TestAnAlreadyResolvedRequestIsNotAFailure(t *testing.T) {
	api := &fakeAPI{
		events:    permissionEvents("4.deadbeefdeadbeef"),
		answerErr: fmt.Errorf("%w: 409", ErrAlreadyResolved),
	}
	a, client := permissionAgent(t, api)
	client.answer = selected("allow")

	result, rpcErr := request(t, a, "session/prompt", textPrompt("conv-1", "go"))
	if rpcErr != nil {
		t.Fatalf("session/prompt failed: %v", rpcErr)
	}
	if result["stopReason"] != "end_turn" {
		t.Errorf("stopReason = %v, want the turn to end normally", result["stopReason"])
	}
	waitForAnswers(t, api, 1)
}

// A client that takes notifications but cannot be asked anything — every ACP
// client can be asked, so this is the defensive case. Nothing is answered on
// its behalf: the web apps are peer clients of the same request, and the server
// denies on the timeout if nobody answers at all.
func TestWithNothingToAskNoAnswerIsInvented(t *testing.T) {
	api := &fakeAPI{events: permissionEvents("4.deadbeefdeadbeef")}
	api.ref = acpAgentRef()
	api.convID = "conv-1"
	a := sessionAgent(t, api, "researcher")
	a.SetNotifier(&fakeNotifier{})
	if _, rpcErr := request(t, a, "session/new", map[string]any{}); rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))
	time.Sleep(20 * time.Millisecond)

	if got := api.answered(); len(got) != 0 {
		t.Errorf("answered %+v with no client to ask, want nothing", got)
	}
}

// Sandbox paths are not this machine's paths — the same rule tool_call updates
// follow (ADR 0015), applied to the tool call a permission request describes.
func TestPermissionToolCallLocationsAreNotPresentedAsLocalPaths(t *testing.T) {
	line := `{"jsonrpc":"2.0","id":"9.1111222233334444","method":"session/request_permission","params":{` +
		`"toolCall":{"kind":"edit","locations":[{"path":"/workspace/lib/foo.ex"}]},` +
		`"options":[{"optionId":"allow","kind":"allow_once"},{"optionId":"reject","kind":"reject_once"}]}}`
	api := &fakeAPI{events: []Event{
		{Kind: "output", Stream: "acp", Data: line},
		stageEvent("turn", "done", `{"stop_reason":"end_turn"}`),
	}}
	a, client := permissionAgent(t, api)
	client.answer = selected("allow")

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))
	waitForAnswers(t, api, 1)

	call, _ := client.askedWith()[0]["toolCall"].(map[string]any)
	if _, present := call["locations"]; present {
		t.Errorf("forwarded sandbox locations as if they were local: %+v", call)
	}
	meta, _ := call["_meta"].(map[string]any)
	if _, present := meta[MetaSandboxLocations]; !present {
		t.Errorf("dropped the sandbox locations instead of filing them under _meta: %+v", call)
	}
}

// The id the answer route takes is the stored line's own, stringified the way
// the server stringifies it — including an adapter that numbers its requests.
func TestARequestIdIsStringifiedTheWayTheServerDoes(t *testing.T) {
	if got := requestID(json.RawMessage(`"4.deadbeef"`)); got != "4.deadbeef" {
		t.Errorf("requestID = %q, want 4.deadbeef", got)
	}
	if got := requestID(json.RawMessage(`12`)); got != "12" {
		t.Errorf("requestID = %q, want 12", got)
	}
}
