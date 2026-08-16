package acp

import (
	"context"
	"encoding/json"
	"sync"
)

// API is the slice of the Fountain HTTP API this adapter needs. It is an
// interface so the protocol logic can be tested without a server, and so
// nothing in this package holds an HTTP client, a token or a base URL — those
// stay in the CLI layer that already resolves them for every other command.
type API interface {
	// Agent resolves a name or id to the agent it names.
	Agent(ctx context.Context, target string) (AgentRef, error)
	// CreateConversation starts a conversation for an agent and returns its id.
	CreateConversation(ctx context.Context, agentID string) (string, error)
	// StreamHead returns the conversation's current last event id, so a follow
	// can skip the history. Called BEFORE a prompt is sent — see prompt.go.
	StreamHead(ctx context.Context, convID string) (string, error)
	// SendPrompt queues a turn. It returns as soon as the server accepts it;
	// the turn's outcome arrives on the stream.
	SendPrompt(ctx context.Context, convID, prompt string, images []Image) error
	// Follow consumes the conversation's event stream from lastEventID until
	// fn reports stop, reconnecting across the disconnects the server produces
	// by design.
	Follow(ctx context.Context, convID, lastEventID string, fn EventFunc) error
	// Interrupt stops the running turn. A conversation with no turn running is
	// not an error — see cancel.
	Interrupt(ctx context.Context, convID string) error
	// Conversation looks up a conversation the adapter did not open, which is
	// what `session/load` is: an editor handing back an id from last week.
	Conversation(ctx context.Context, convID string) (ConversationRef, error)
	// Replay drains the conversation's stored ACP events from the beginning,
	// oldest first, and closes. Unlike Follow it does not wait for more.
	Replay(ctx context.Context, convID string, fn EventFunc) error
}

// ConversationRef is what the adapter needs to know about a conversation it is
// being asked to reopen.
type ConversationRef struct {
	ID      string
	Runtime string
	Status  string
	// Agent and Model describe what this conversation runs, for the model
	// state a reopened session reports.
	Agent string
	Model string
	// ACP reports whether this conversation's output was stored as protocol.
	// A legacy-runtime conversation has a transcript, but not one this adapter
	// can replay — see #702.
	ACP bool
}

// AgentRef is what the adapter needs to know about a Fountain agent.
type AgentRef struct {
	ID      string
	Name    string
	Runtime string
	// Model is the agent's canonical provider/model id, e.g.
	// "anthropic/claude-sonnet-4-6". Reported to the client as the session's
	// current model — see modelState.
	Model string
	// ACP reports whether the runtime speaks the protocol. The server derives
	// it (GET /api/agents/:id) precisely so this file does not carry a list of
	// runtime names that goes stale the day a held-back runtime is converted.
	ACP bool
}

// Session is one editor-visible conversation.
type Session struct {
	// ID is the Fountain conversation id, used verbatim as the ACP session id.
	//
	// This aliasing is deliberate. ACP session ids are opaque to the client,
	// and minting our own would mean holding a session→conversation map that
	// dies with the process — so an editor reopening tomorrow could hand back
	// a session id nothing could resolve, and `session/load` (#703) would have
	// to persist a map to disk to work at all. The conversation id is already
	// durable, already addressable, and already the thing the web UI shows.
	//
	// What must NOT leak upward is the third id: `runtime_session_id` belongs
	// to the runtime inside the sandbox, means nothing outside the sandbox
	// that holds it, and does not survive a reclaim (#649).
	ID    string
	Agent AgentRef
}

// sessions is the in-memory registry of sessions opened on this connection.
type sessions struct {
	mu sync.Mutex
	m  map[string]Session
}

func newSessions() *sessions { return &sessions{m: map[string]Session{}} }

func (s *sessions) put(sess Session) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.m[sess.ID] = sess
}

func (s *sessions) get(id string) (Session, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, ok := s.m[id]
	return sess, ok
}

type newSessionParams struct {
	Cwd        string            `json:"cwd"`
	MCPServers []json.RawMessage `json:"mcpServers"`
}

func (a *Agent) newSession(ctx context.Context, raw json.RawMessage) (any, error) {
	var params newSessionParams
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &params); err != nil {
			return nil, Errorf(CodeInvalidParams, "session/new: %s", err)
		}
	}

	if err := a.requireReady(); err != nil {
		return nil, err
	}

	// `cwd` is the editor's project directory, on the developer's machine. The
	// agent works in a sandbox that cloned its own checkout, so this path
	// names nothing we can act on — logged, so an editor's expectation is
	// visible in the record, and otherwise ignored. Same for the editor's MCP
	// servers: they are processes on the developer's machine, and a Fountain
	// agent carries its own MCP configuration to the sandbox (#673).
	if params.Cwd != "" || len(params.MCPServers) > 0 {
		a.log.Info("ignoring client-side session parameters",
			"cwd", params.Cwd,
			"mcpServers", len(params.MCPServers),
			"why", "the agent runs in a sandbox, not on this machine")
	}

	if a.agentTarget == "" {
		return nil, Errorf(CodeInvalidParams,
			"no Fountain agent configured — spawn this as `fountain acp --agent <name-or-id>`")
	}

	ref, err := a.api.Agent(ctx, a.agentTarget)
	if err != nil {
		return nil, Errorf(CodeInternalError,
			"could not resolve agent %q on %s: %s", a.agentTarget, a.auth.Describe(), err)
	}

	// The refusal is the honest half of #702. An agent on the legacy path
	// emits its runtime's own dialect, which this adapter deliberately cannot
	// parse — forwarding nothing would leave an editor rendering an empty
	// conversation while a sandbox ran and billed.
	if !ref.ACP {
		return nil, Errorf(CodeInvalidParams,
			"agent %q runs the %s runtime, which does not speak ACP — use it from the web UI or the CLI, "+
				"or point this at an agent whose runtime does",
			ref.Name, ref.Runtime)
	}

	convID, err := a.api.CreateConversation(ctx, ref.ID)
	if err != nil {
		return nil, Errorf(CodeInternalError, "could not start a conversation for %q: %s", ref.Name, err)
	}

	sess := Session{ID: convID, Agent: ref}
	a.sessions.put(sess)
	a.log.Info("session opened",
		"sessionId", sess.ID, "agent", ref.Name, "runtime", ref.Runtime, "model", ref.Model)

	return map[string]any{
		"sessionId": sess.ID,
		"models":    modelState(ref),
	}, nil
}

// modelState reports the session's model.
//
// A Fountain agent's model is part of the agent, chosen once and shared by
// every conversation it runs — so the list has exactly one entry and it is
// also the current one. That is not a placeholder: switching models here would
// mean editing the agent, which would silently change what every other
// conversation on it runs, and `session/set_model` is not implemented for that
// reason.
//
// Reporting it at all matters because clients use this list to decide the
// agent is usable: Buzz refuses an agent that reports no models, with a
// message about the CLI not being signed in — a true statement about a
// different problem.
func modelState(ref AgentRef) map[string]any {
	model := ref.Model
	if model == "" {
		// An agent with no model set runs the runtime's own default. Saying so
		// beats reporting an empty list, which reads as "no models available".
		model = "default"
	}

	return map[string]any{
		"currentModelId": model,
		"availableModels": []map[string]any{{
			"modelId":     model,
			"name":        model,
			"description": "Configured on the Fountain agent \"" + ref.Name + "\". Change it on the agent, not here.",
		}},
	}
}

// configOptions reports a session's settable options as an ACP config-option
// list, echoed back from setConfigOption so a client that pushed one sees the
// resulting state. A Fountain agent exposes exactly one option, its model, and
// it is fixed — chosen on the agent, shared by every conversation — so the list
// has a single entry that is also the current value. See setConfigOption for
// why the set is accepted but never applied.
func configOptions(ref AgentRef) []map[string]any {
	model := ref.Model
	if model == "" {
		model = "default"
	}
	return []map[string]any{{
		"configId": "model", "id": "model", "name": "Model",
		"currentValue": model, "value": model,
		"options": []map[string]any{{"optionId": model, "id": model, "name": model}},
	}}
}

// requireReady is the gate the session methods share: a client that has not
// handshaked, or has no working credentials, gets a protocol error naming
// which of the two it is rather than an authorization failure from three
// layers down.
func (a *Agent) requireReady() error {
	if !a.Initialized() {
		return Errorf(CodeInvalidRequest, "initialize must come first")
	}
	if !a.Authenticated() {
		return Errorf(CodeAuthRequired,
			"not authenticated for %s — run `fountain auth login`", a.auth.Describe())
	}
	return nil
}
