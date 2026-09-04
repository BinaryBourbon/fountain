// Package backend implements the buzz-backend-fountain remote-agents provider
// (ADR 0020 Phase 3, #738): the small binary Buzz's desktop discovers and hands
// a one-shot deploy, which stands up a Fountain-hosted Buzz agent.
//
// The contract (block/buzz docs/remote-agents.md): one JSON object in on stdin,
// one JSON object out on stdout, two ops — "info" and "deploy". After deploy
// there is no management channel; lifecycle happens on the relay. This provider
// maps deploy onto Fountain's POST /api/buzz/agents, which is idempotent on the
// agent's Nostr pubkey, so a repeated deploy converges. The Nostr secret never
// touches the desktop's provider_config: Fountain credentials are ambient, and
// the deploy payload carries the agent key straight through to Fountain, which
// holds it server-side.
package backend

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// ProtocolVersion is the provider-protocol revision this binary speaks. The
// desktop refuses a mismatch before it sends any secret, so it is explicit.
const ProtocolVersion = 1

const (
	name        = "fountain"
	version     = "1"
	description = "Runs a Buzz agent as a hosted Fountain agent — the harness lives on your Fountain instance, not this desktop."
)

// Request is either op, distinguished by "op".
type Request struct {
	Op             string          `json:"op"`
	RequestID      string          `json:"request_id"`
	Agent          AgentPayload    `json:"agent"`
	ProviderConfig json.RawMessage `json:"provider_config"`
}

// AgentPayload is the subset of the deploy payload this provider uses. Legacy
// bookkeeping fields are intentionally ignored (they must not be mapped to env).
type AgentPayload struct {
	Name           string `json:"name"`
	RelayURL       string `json:"relay_url"`
	PrivateKeyNsec string `json:"private_key_nsec"`
	AuthTag        string `json:"auth_tag"`
	Provider       string `json:"provider"`
	Launch         Launch `json:"launch"`
	// The inbound author gate the desktop projects from the agent record —
	// buzz-acp's --respond-to mode and its allowlist. Fountain sets these on the
	// hosted harness; dropping them here left every hosted agent owner-only
	// whatever the record said (#790).
	RespondTo          string   `json:"respond_to"`
	RespondToAllowlist []string `json:"respond_to_allowlist"`
}

// Launch is the normative launch block; we read only the owner attestation.
type Launch struct {
	OwnerPubkey string `json:"owner_pubkey"`
}

// InfoResponse answers `info`.
type InfoResponse struct {
	OK              bool            `json:"ok"`
	Name            string          `json:"name"`
	Version         string          `json:"version"`
	ProtocolVersion int             `json:"protocol_version"`
	Description     string          `json:"description"`
	ConfigSchema    json.RawMessage `json:"config_schema"`
}

// DeployResponse answers `deploy`. On failure OK is false and Error is set — an
// in-band failure, distinct from a nonzero process exit (which means the
// provider could not read its input at all).
type DeployResponse struct {
	OK      bool   `json:"ok"`
	AgentID string `json:"agent_id,omitempty"`
	Error   string `json:"error,omitempty"`
}

// Fountain is the slice of the Fountain API the provider needs. An interface so
// deploy is testable without a live instance.
type Fountain interface {
	// ResolveAgent maps a user-supplied agent name or id to its id.
	ResolveAgent(nameOrID string) (string, error)
	// ResolveEnvironment maps a user-supplied environment name or id to its id.
	ResolveEnvironment(nameOrID string) (string, error)
	// Provision creates or converges a hosted Buzz agent, returning its id.
	Provision(body ProvisionBody) (string, error)
}

// ProvisionBody is the POST /api/buzz/agents payload.
type ProvisionBody struct {
	Name           string `json:"name"`
	RelayURL       string `json:"relay_url"`
	AgentID        string `json:"agent_id"`
	Pubkey         string `json:"pubkey"`
	PrivateKeyNsec string `json:"private_key_nsec"`
	AuthTag        string `json:"auth_tag"`
	DisplayName    string `json:"display_name,omitempty"`
	// Optional per-identity environment override (#783): the environment this
	// identity's conversations are provisioned from instead of the agent's own.
	EnvironmentID string `json:"environment_id,omitempty"`
	// Optional per-identity sandbox mode (ADR 0023): `ephemeral` or
	// `persistent`, where this identity's conversations run. Omitted means
	// the agent's default.
	SandboxMode string `json:"sandbox_mode,omitempty"`
	// The harness's inbound author gate (#790). Omitted when the desktop sent
	// none, so Fountain applies its own owner-only default.
	RespondTo          string   `json:"respond_to,omitempty"`
	RespondToAllowlist []string `json:"respond_to_allowlist,omitempty"`
}

// Info returns the provider descriptor. config_schema is the desktop's settings
// form: non-secret selectors only — which Fountain agent to run as, and
// optionally which environment to run it under. Credentials are deliberately
// NOT here — the desktop rejects a provider_config key named like a secret, so
// Fountain auth is ambient (env / the fountain CLI creds).
func Info() InfoResponse {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "agent": {
      "type": "string",
      "title": "Fountain agent",
      "description": "Name or id of the Fountain agent this Buzz identity runs as."
    },
    "environment": {
      "type": "string",
      "title": "Fountain environment (optional)",
      "description": "Name or id of a Fountain environment to provision this identity's conversations from, instead of the agent's own. Leave blank to use the agent's."
    },
    "sandbox_mode": {
      "type": "string",
      "title": "Sandbox mode (optional)",
      "enum": ["ephemeral", "persistent"],
      "description": "Where this identity's conversations run: a sandbox per conversation, or the agent's one persistent machine. Leave blank to use the agent's default."
    }
  },
  "required": ["agent"]
}`)

	return InfoResponse{
		OK:              true,
		Name:            name,
		Version:         version,
		ProtocolVersion: ProtocolVersion,
		Description:     description,
		ConfigSchema:    schema,
	}
}

// Deploy converges a hosted Buzz agent for the request, using f to talk to
// Fountain. Errors are returned as an in-band DeployResponse{OK:false}.
func Deploy(req Request, f Fountain) DeployResponse {
	// Refuse before any mutation if there is no owner to attest the agent —
	// neither an auth tag nor a launch owner pubkey (docs/remote-agents.md).
	if strings.TrimSpace(req.Agent.AuthTag) == "" && strings.TrimSpace(req.Agent.Launch.OwnerPubkey) == "" {
		return fail("refusing to deploy an agent with no owner (no auth_tag and no launch.owner_pubkey)")
	}

	// relay-mesh is not a deployable substrate; every provider refuses it.
	if req.Agent.Provider == "relay-mesh" {
		return fail("refusing to deploy: relay-mesh is not a deployable substrate")
	}

	pubkey, err := derivePubkey(req.Agent.PrivateKeyNsec)
	if err != nil {
		return fail(fmt.Sprintf("could not derive the agent pubkey from its key: %v", err))
	}

	cfg, err := providerConfig(req.ProviderConfig)
	if err != nil {
		return fail(err.Error())
	}

	agentID, err := f.ResolveAgent(cfg.Agent)
	if err != nil {
		return fail(fmt.Sprintf("no such Fountain agent %q: %v", cfg.Agent, err))
	}

	// The environment selector is optional; blank means the agent's own. A
	// selector that names nothing is a refusal, not a silent fallback — the
	// user asked for a specific baseline and would otherwise get another.
	envID := ""
	if cfg.Environment != "" {
		envID, err = f.ResolveEnvironment(cfg.Environment)
		if err != nil {
			return fail(fmt.Sprintf("no such Fountain environment %q: %v", cfg.Environment, err))
		}
	}

	id, err := f.Provision(ProvisionBody{
		Name:           req.Agent.Name,
		RelayURL:       req.Agent.RelayURL,
		AgentID:        agentID,
		Pubkey:         pubkey,
		PrivateKeyNsec: req.Agent.PrivateKeyNsec,
		AuthTag:        req.Agent.AuthTag,
		DisplayName:    req.Agent.Name,
		EnvironmentID:  envID,
		SandboxMode:    cfg.SandboxMode,
		// Pass the author gate through verbatim; Fountain validates the mode and
		// the pubkeys and refuses an allowlist with nothing on it.
		RespondTo:          strings.TrimSpace(req.Agent.RespondTo),
		RespondToAllowlist: trimmedList(req.Agent.RespondToAllowlist),
	})
	if err != nil {
		return fail(fmt.Sprintf("provisioning failed: %v", err))
	}

	return DeployResponse{OK: true, AgentID: id}
}

// derivePubkey returns the 64-hex x-only Nostr pubkey for a secret key given as
// nsec (bech32) or raw hex — the convergence key Fountain dedups on.
func derivePubkey(key string) (string, error) {
	sk := strings.TrimSpace(key)
	if sk == "" {
		return "", fmt.Errorf("empty private key")
	}

	if strings.HasPrefix(sk, "nsec1") {
		_, decoded, err := nip19.Decode(sk)
		if err != nil {
			return "", err
		}
		hex, ok := decoded.(string)
		if !ok {
			return "", fmt.Errorf("unexpected nsec payload")
		}
		sk = hex
	}

	return nostr.GetPublicKey(sk)
}

// providerConfigFields is the desktop's provider_config as this provider reads
// it — the two selectors from Info's config_schema, trimmed.
type providerConfigFields struct {
	Agent       string `json:"agent"`
	Environment string `json:"environment"`
	SandboxMode string `json:"sandbox_mode"`
}

func providerConfig(raw json.RawMessage) (providerConfigFields, error) {
	var cfg providerConfigFields
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &cfg)
	}
	cfg.Agent = strings.TrimSpace(cfg.Agent)
	cfg.Environment = strings.TrimSpace(cfg.Environment)
	cfg.SandboxMode = strings.TrimSpace(cfg.SandboxMode)
	if cfg.Agent == "" {
		return cfg, fmt.Errorf("no Fountain agent configured — set the `agent` field")
	}
	// Refused here, not at Fountain: the desktop shows this message, and a
	// half-provisioned identity is worse than a rejected form.
	if cfg.SandboxMode != "" && cfg.SandboxMode != "ephemeral" && cfg.SandboxMode != "persistent" {
		return cfg, fmt.Errorf("sandbox_mode must be ephemeral or persistent, got %q", cfg.SandboxMode)
	}
	return cfg, nil
}

// trimmedList drops blank entries; nil when nothing remains so the field is
// omitted from the provision body rather than sent as [].
func trimmedList(in []string) []string {
	var out []string
	for _, v := range in {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}

func fail(msg string) DeployResponse { return DeployResponse{OK: false, Error: msg} }
