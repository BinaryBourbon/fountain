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
}

// Info returns the provider descriptor. config_schema is the desktop's settings
// form: only a non-secret selector (which Fountain agent to run as). Credentials
// are deliberately NOT here — the desktop rejects a provider_config key named
// like a secret, so Fountain auth is ambient (env / the fountain CLI creds).
func Info() InfoResponse {
	schema := json.RawMessage(`{
  "type": "object",
  "properties": {
    "agent": {
      "type": "string",
      "title": "Fountain agent",
      "description": "Name or id of the Fountain agent this Buzz identity runs as."
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

	agentSel, err := providerAgent(req.ProviderConfig)
	if err != nil {
		return fail(err.Error())
	}

	agentID, err := f.ResolveAgent(agentSel)
	if err != nil {
		return fail(fmt.Sprintf("no such Fountain agent %q: %v", agentSel, err))
	}

	id, err := f.Provision(ProvisionBody{
		Name:           req.Agent.Name,
		RelayURL:       req.Agent.RelayURL,
		AgentID:        agentID,
		Pubkey:         pubkey,
		PrivateKeyNsec: req.Agent.PrivateKeyNsec,
		AuthTag:        req.Agent.AuthTag,
		DisplayName:    req.Agent.Name,
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

func providerAgent(raw json.RawMessage) (string, error) {
	var cfg struct {
		Agent string `json:"agent"`
	}
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &cfg)
	}
	if strings.TrimSpace(cfg.Agent) == "" {
		return "", fmt.Errorf("no Fountain agent configured — set the `agent` field")
	}
	return cfg.Agent, nil
}

func fail(msg string) DeployResponse { return DeployResponse{OK: false, Error: msg} }
