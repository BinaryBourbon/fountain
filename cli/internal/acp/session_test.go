package acp

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
)

type fakeAPI struct {
	mu        sync.Mutex
	ref       AgentRef
	agentErr  error
	createErr error

	resolved []string
	created  []string
	convID   string

	// prompt path
	head       string
	headErr    error
	promptErr  error
	followErr  error
	events     []Event
	prompts    []sentPrompt
	followFrom []string

	// cancel path
	interruptErr error
	interrupted  []string
	onInterrupt  func()
	// followBlock, when set, holds Follow open until it is closed — a stand-in
	// for a turn that sits there until something stops it. followStarted, when
	// set, is closed once Follow has been entered, so a test can send a cancel
	// at the moment a real one would arrive.
	followBlock   chan struct{}
	followStarted chan struct{}

	// load path
	conversation    ConversationRef
	conversationErr error
	replay          []Event
	replayErr       error
}

type sentPrompt struct {
	convID string
	text   string
	images []Image
}

func (f *fakeAPI) Agent(_ context.Context, target string) (AgentRef, error) {
	f.resolved = append(f.resolved, target)
	if f.agentErr != nil {
		return AgentRef{}, f.agentErr
	}
	return f.ref, nil
}

func (f *fakeAPI) CreateConversation(_ context.Context, agentID string) (string, error) {
	f.created = append(f.created, agentID)
	if f.createErr != nil {
		return "", f.createErr
	}
	if f.convID == "" {
		return "conv-1", nil
	}
	return f.convID, nil
}

func (f *fakeAPI) StreamHead(context.Context, string) (string, error) {
	if f.headErr != nil {
		return "", f.headErr
	}
	return f.head, nil
}

func (f *fakeAPI) SendPrompt(_ context.Context, convID, text string, images []Image) error {
	f.prompts = append(f.prompts, sentPrompt{convID: convID, text: text, images: images})
	return f.promptErr
}

func (f *fakeAPI) Interrupt(_ context.Context, convID string) error {
	f.mu.Lock()
	f.interrupted = append(f.interrupted, convID)
	onInterrupt := f.onInterrupt
	f.mu.Unlock()

	if onInterrupt != nil {
		onInterrupt()
	}
	return f.interruptErr
}

func (f *fakeAPI) Follow(_ context.Context, _, lastEventID string, fn EventFunc) error {
	f.mu.Lock()
	f.followFrom = append(f.followFrom, lastEventID)
	block := f.followBlock
	started := f.followStarted
	f.mu.Unlock()

	if started != nil {
		close(started)
	}
	if block != nil {
		<-block
	}
	if f.followErr != nil {
		return f.followErr
	}
	for _, ev := range f.events {
		stop, err := fn(ev)
		if err != nil {
			return err
		}
		if stop {
			return nil
		}
	}
	return nil
}

func (f *fakeAPI) Conversation(context.Context, string) (ConversationRef, error) {
	if f.conversationErr != nil {
		return ConversationRef{}, f.conversationErr
	}
	return f.conversation, nil
}

func (f *fakeAPI) Replay(_ context.Context, _ string, fn EventFunc) error {
	if f.replayErr != nil {
		return f.replayErr
	}
	for _, ev := range f.replay {
		stop, err := fn(ev)
		if err != nil {
			return err
		}
		if stop {
			return nil
		}
	}
	return nil
}

func acpAgentRef() AgentRef {
	return AgentRef{ID: "agent-1", Name: "researcher", Runtime: "claude", ACP: true}
}

// sessionAgent returns an initialized, authenticated agent — the state a real
// one is in by the time `session/new` arrives.
func sessionAgent(t *testing.T, api *fakeAPI, target string) *Agent {
	t.Helper()

	a := NewAgent(&fakeAuth{available: true}, api, target, "test", discardLogger())
	if _, rpcErr := request(t, a, "initialize", map[string]any{"protocolVersion": ProtocolVersion}); rpcErr != nil {
		t.Fatalf("initialize failed: %v", rpcErr)
	}
	return a
}

func TestNewSessionCreatesAConversationForTheConfiguredAgent(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-42"}
	a := sessionAgent(t, api, "researcher")

	result, rpcErr := request(t, a, "session/new", map[string]any{"cwd": "/home/dev/proj"})
	if rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}

	if result["sessionId"] != "conv-42" {
		t.Errorf("sessionId = %v, want the conversation id", result["sessionId"])
	}
	if len(api.resolved) != 1 || api.resolved[0] != "researcher" {
		t.Errorf("resolved = %v, want [researcher]", api.resolved)
	}
	if len(api.created) != 1 || api.created[0] != "agent-1" {
		t.Errorf("created for = %v, want [agent-1]", api.created)
	}
}

// The session id IS the conversation id, deliberately: an editor that stored
// it yesterday must be able to hand it back to a process started today, and a
// minted id would need a map that dies with the process.
func TestSessionIsAddressableByTheConversationID(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-42"}
	a := sessionAgent(t, api, "researcher")

	request(t, a, "session/new", map[string]any{})

	sess, ok := a.sessions.get("conv-42")
	if !ok {
		t.Fatal("session not registered under the conversation id")
	}
	if sess.Agent.Name != "researcher" {
		t.Errorf("session agent = %v, want researcher", sess.Agent.Name)
	}
}

// #702: an agent on the legacy path emits its runtime's own dialect, which
// this adapter deliberately cannot parse. Starting the conversation anyway
// would bill a sandbox to render nothing.
func TestNewSessionRefusesARuntimeThatDoesNotSpeakACP(t *testing.T) {
	api := &fakeAPI{ref: AgentRef{ID: "agent-2", Name: "gem", Runtime: "gemini", ACP: false}}
	a := sessionAgent(t, api, "gem")

	_, rpcErr := request(t, a, "session/new", map[string]any{})
	if rpcErr == nil {
		t.Fatal("session/new accepted an agent whose runtime does not speak ACP")
	}
	if !strings.Contains(rpcErr.Message, "gemini") {
		t.Errorf("message = %q, want it to name the runtime", rpcErr.Message)
	}
	if len(api.created) != 0 {
		t.Errorf("a conversation was created for a runtime we cannot render: %v", api.created)
	}
}

func TestNewSessionWithNoAgentConfiguredSaysHowToConfigureOne(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef()}
	a := sessionAgent(t, api, "")

	_, rpcErr := request(t, a, "session/new", map[string]any{})
	if rpcErr == nil {
		t.Fatal("session/new succeeded with no agent configured")
	}
	if !strings.Contains(rpcErr.Message, "--agent") {
		t.Errorf("message = %q, want it to name the flag that fixes it", rpcErr.Message)
	}
	if len(api.resolved) != 0 {
		t.Errorf("resolved an agent that was never configured: %v", api.resolved)
	}
}

func TestNewSessionReportsAnUnresolvableAgent(t *testing.T) {
	api := &fakeAPI{agentErr: errors.New(`no agent named "typo"`)}
	a := sessionAgent(t, api, "typo")

	_, rpcErr := request(t, a, "session/new", map[string]any{})
	if rpcErr == nil {
		t.Fatal("session/new succeeded with an agent that does not exist")
	}
	if !strings.Contains(rpcErr.Message, "typo") {
		t.Errorf("message = %q, want it to name the agent it looked for", rpcErr.Message)
	}
	// The instance matters: the usual cause is an editor pointed at the wrong
	// one, where every agent name is legitimately absent.
	if !strings.Contains(rpcErr.Message, "example.test") {
		t.Errorf("message = %q, want it to name the instance it asked", rpcErr.Message)
	}
}

func TestNewSessionReportsAFailedConversationStart(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), createErr: errors.New("http 402: subscription_required")}
	a := sessionAgent(t, api, "researcher")

	_, rpcErr := request(t, a, "session/new", map[string]any{})
	if rpcErr == nil {
		t.Fatal("session/new reported success for a conversation that was never created")
	}
	if !strings.Contains(rpcErr.Message, "subscription_required") {
		t.Errorf("message = %q, want it to carry the server's reason", rpcErr.Message)
	}
}

// A client that skips the handshake gets told which step it missed, rather
// than an error from three layers down.
func TestNewSessionBeforeInitializeIsRefused(t *testing.T) {
	a := NewAgent(&fakeAuth{available: true}, &fakeAPI{ref: acpAgentRef()}, "researcher", "test", discardLogger())

	_, rpcErr := request(t, a, "session/new", map[string]any{})
	if rpcErr == nil || rpcErr.Code != CodeInvalidRequest {
		t.Fatalf("want an invalid-request error, got %v", rpcErr)
	}
	if !strings.Contains(rpcErr.Message, "initialize") {
		t.Errorf("message = %q, want it to name the missing step", rpcErr.Message)
	}
}

func TestNewSessionWithoutCredentialsIsRefused(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef()}
	a := NewAgent(&fakeAuth{available: false}, api, "researcher", "test", discardLogger())
	request(t, a, "initialize", map[string]any{"protocolVersion": ProtocolVersion})

	_, rpcErr := request(t, a, "session/new", map[string]any{})
	if rpcErr == nil || rpcErr.Code != CodeAuthRequired {
		t.Fatalf("want an auth-required error, got %v", rpcErr)
	}
	if len(api.created) != 0 {
		t.Errorf("created a conversation for an unauthenticated client: %v", api.created)
	}
}

// The editor's cwd and its MCP servers describe the developer's machine. The
// agent runs in a sandbox, so acting on either would be acting on the wrong
// computer — they are logged and ignored, and the session still opens.
func TestClientSideSessionParametersAreIgnoredNotFatal(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-7"}
	a := sessionAgent(t, api, "researcher")

	result, rpcErr := request(t, a, "session/new", map[string]any{
		"cwd": "/home/dev/proj",
		"mcpServers": []map[string]any{
			{"name": "local-fs", "command": "/usr/local/bin/mcp-fs"},
		},
	})
	if rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}
	if result["sessionId"] != "conv-7" {
		t.Errorf("sessionId = %v, want conv-7", result["sessionId"])
	}
}

func TestTwoSessionsAreTrackedIndependently(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-a"}
	a := sessionAgent(t, api, "researcher")

	request(t, a, "session/new", map[string]any{})
	api.convID = "conv-b"
	request(t, a, "session/new", map[string]any{})

	for _, id := range []string{"conv-a", "conv-b"} {
		if _, ok := a.sessions.get(id); !ok {
			t.Errorf("session %s was not registered", id)
		}
	}
}

func TestSetConfigOptionIsAcceptedRatherThanRejected(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-9"}
	a := sessionAgent(t, api, "researcher")

	if _, rpcErr := request(t, a, "session/new", map[string]any{}); rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}

	// A client that pushes a model at session start — as OpenClaw's acpx does —
	// must not get "method not found". Rejecting it makes acpx abort the whole
	// turn; the method is implemented so the request is accepted.
	result, rpcErr := request(t, a, "session/set_config_option", map[string]any{
		"sessionId": "conv-9",
		"configId":  "model",
		"value":     "anthropic/claude-something-else",
	})
	if rpcErr != nil {
		t.Fatalf("set_config_option returned an error: %v", rpcErr)
	}

	// The push is accepted but not applied: the agent's model is authoritative,
	// so the echoed option still reports the agent's own value (here "default",
	// since the test ref sets no model), never the client's.
	opts, ok := result["configOptions"].([]map[string]any)
	if !ok || len(opts) == 0 {
		t.Fatalf("configOptions = %#v, want a non-empty list", result["configOptions"])
	}
	if got := opts[0]["currentValue"]; got != "default" {
		t.Errorf("model currentValue = %v, want the agent's value \"default\" (the client's push must not apply)", got)
	}
}

func TestSetConfigOptionOnAnUnknownSessionIsRefused(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-9"}
	a := sessionAgent(t, api, "researcher")

	_, rpcErr := request(t, a, "session/set_config_option", map[string]any{
		"sessionId": "nope",
		"configId":  "model",
		"value":     "x",
	})
	if rpcErr == nil {
		t.Fatal("expected an error for an unknown session")
	}
	if rpcErr.Code != CodeInvalidParams {
		t.Errorf("code = %d, want CodeInvalidParams (%d)", rpcErr.Code, CodeInvalidParams)
	}
}
