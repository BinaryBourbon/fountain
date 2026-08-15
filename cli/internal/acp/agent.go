package acp

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
)

// ProtocolVersion is the ACP major version this agent speaks. It matches what
// the server's peer offers downward (Fountain.Runtimes.ACP.initialize_params/0),
// which is not a coincidence worth breaking: Fountain is a proxy, and a
// version it can receive but not re-emit is a translation problem it exists to
// not have.
const ProtocolVersion = 1

// AuthMethodID is the id an editor passes back to `authenticate`.
const AuthMethodID = "fountain-cli-login"

// Auth is what the agent needs to know about credentials, split by cost.
//
// Available is a local check — a file read, no network — because it runs
// inside `initialize`, and an editor that waits on a round trip to decide
// whether to show a login prompt feels broken before it has done anything.
// Verify is the network check, and only `authenticate` pays for it.
type Auth interface {
	Available() bool
	Verify(ctx context.Context) error
	// Describe names where the credentials would come from, for log lines
	// and error messages. A wrong-instance or wrong-profile misconfiguration
	// is otherwise invisible from inside an editor.
	Describe() string
}

// Agent handles the ACP methods an editor calls.
//
// v1 is a control surface, not a workspace: it declares no client filesystem
// or terminal capabilities and requests none. A Fountain agent edits a
// sprite's files on a machine that is not the developer's, and ADR 0015 is
// explicit that pretending otherwise "produces an agent that appears to be
// editing the open project and is not". Read-through and workspace sync are
// separate decisions with their own ADRs — they do not arrive through here.
type Agent struct {
	auth Auth
	api  API
	log  *slog.Logger

	// agentTarget is the Fountain agent (name or id) this process opens
	// sessions against. ACP's `session/new` carries a `cwd` and a list of MCP
	// servers but no notion of *which* agent, and the unit an editor is
	// reaching for here is a provisioned Fountain agent — an environment,
	// vault overrides, skills, MCP servers and inference credentials that
	// never touch the developer's machine. So the choice is made where the
	// editor already configures things: one agent-server entry per agent,
	// `fountain acp --agent <name-or-id>`. Carrying it in `session/new`'s
	// `_meta` instead would put the decision in a field most clients do not
	// surface, and a default in the credentials file would make two editors
	// on one machine fight over it.
	agentTarget string

	sessions *sessions

	mu            sync.Mutex
	notifier      Notifier
	initialized   bool
	authenticated bool
	negotiated    int
}

// NewAgent returns an agent bound to a credential source, the Fountain API,
// and the agent sessions open against.
func NewAgent(auth Auth, api API, agentTarget string, log *slog.Logger) *Agent {
	return &Agent{
		auth:        auth,
		api:         api,
		agentTarget: agentTarget,
		sessions:    newSessions(),
		log:         log,
	}
}

type initializeParams struct {
	ProtocolVersion    int             `json:"protocolVersion"`
	ClientCapabilities json.RawMessage `json:"clientCapabilities"`
}

type authenticateParams struct {
	MethodID string `json:"methodId"`
}

// Request dispatches one ACP method.
func (a *Agent) Request(ctx context.Context, method string, params json.RawMessage) (any, error) {
	switch method {
	case "initialize":
		return a.initialize(params)
	case "authenticate":
		return a.authenticate(ctx, params)
	case "session/new":
		return a.newSession(ctx, params)
	case "session/prompt":
		return a.prompt(ctx, params)
	default:
		return nil, Errorf(CodeMethodNotFound, "method not found: %s", method)
	}
}

// Notify handles client notifications. There are none this agent acts on yet;
// `session/cancel` arrives here when it lands (#704).
func (a *Agent) Notify(_ context.Context, method string, _ json.RawMessage) {
	a.log.Debug("ignoring notification", "method", method)
}

func (a *Agent) initialize(raw json.RawMessage) (any, error) {
	var params initializeParams
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &params); err != nil {
			return nil, Errorf(CodeInvalidParams, "initialize: %s", err)
		}
	}

	// The protocol negotiates down: answer with the highest version both ends
	// speak. There is no floor to refuse below yet, because ProtocolVersion is
	// also the oldest version that exists — when a v2 ships, the refusal for a
	// client below our floor belongs here, not in the session methods, where
	// it would surface as a mid-conversation failure.
	negotiated := params.ProtocolVersion
	if negotiated <= 0 || negotiated > ProtocolVersion {
		negotiated = ProtocolVersion
	}

	// The client's params are logged whole and stored not at all. Whatever it
	// offers — fs/read_text_file, terminals — v1 uses none of it, and this
	// line is what makes that visible when an editor asks why its
	// capabilities were ignored.
	a.log.Info("initialize",
		"protocolVersion", negotiated,
		"params", string(raw),
		"credentials", a.auth.Describe())

	authenticated := a.auth.Available()

	a.mu.Lock()
	a.initialized = true
	a.negotiated = negotiated
	// Holding credentials is not proof they work — `authenticate` is what
	// verifies them. It is proof we should not ask the editor to log in.
	a.authenticated = authenticated
	a.mu.Unlock()

	return map[string]any{
		"protocolVersion":   negotiated,
		"agentCapabilities": agentCapabilities(),
		"authMethods":       authMethods(authenticated),
	}, nil
}

// agentCapabilities is deliberately the smallest honest set.
//
// loadSession stays false until the replay path exists (#703): claiming it
// obliges us to replay a whole conversation as session/update notifications
// before answering, and an agent that claims it and does not do it leaves an
// editor showing an empty transcript for a conversation that has one.
//
// `image` is true because the prompt path carries images to the API, which has
// taken them since before this adapter existed. `embeddedContext` stays false:
// it means the editor may inline a local file's contents, and this agent works
// on a sandbox's filesystem, so accepting them would be accepting context
// about a machine the agent cannot see.
func agentCapabilities() map[string]any {
	return map[string]any{
		"loadSession": false,
		"promptCapabilities": map[string]any{
			"image":           true,
			"audio":           false,
			"embeddedContext": false,
		},
	}
}

// authMethods advertises the one way in, and only when it is needed. An
// editor shown a login prompt for a CLI that is already logged in has been
// told something false about its own state.
func authMethods(authenticated bool) []map[string]any {
	if authenticated {
		return []map[string]any{}
	}
	return []map[string]any{{
		"id":          AuthMethodID,
		"name":        "Fountain CLI login",
		"description": "Run `fountain auth login` in a terminal, then retry.",
	}}
}

func (a *Agent) authenticate(ctx context.Context, raw json.RawMessage) (any, error) {
	var params authenticateParams
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &params); err != nil {
			return nil, Errorf(CodeInvalidParams, "authenticate: %s", err)
		}
	}
	if params.MethodID != "" && params.MethodID != AuthMethodID {
		return nil, Errorf(CodeInvalidParams, "unknown auth method %q", params.MethodID)
	}

	if !a.auth.Available() {
		return nil, Errorf(CodeAuthRequired,
			"no credentials for %s — run `fountain auth login`", a.auth.Describe())
	}

	if err := a.auth.Verify(ctx); err != nil {
		// The message is the whole value of this branch: it is read inside an
		// editor by someone who cannot see a 401.
		return nil, Errorf(CodeAuthRequired,
			"credentials for %s were rejected (%s) — run `fountain auth login`",
			a.auth.Describe(), err)
	}

	a.mu.Lock()
	a.authenticated = true
	a.mu.Unlock()

	a.log.Info("authenticated", "credentials", a.auth.Describe())
	return nil, nil
}

// Authenticated reports whether the session may call the session methods.
// The session methods do not exist yet; this is what they will gate on.
func (a *Agent) Authenticated() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.authenticated
}

// Initialized reports whether `initialize` has completed.
func (a *Agent) Initialized() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.initialized
}
