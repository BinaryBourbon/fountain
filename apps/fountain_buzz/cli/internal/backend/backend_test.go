package backend

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

var errNoEnv = errors.New("no environment named \"nope\"")

// fakeFountain records calls and returns canned results.
type fakeFountain struct {
	resolveTo     string
	resolveErr    error
	resolveEnvTo  string
	resolveEnvErr error
	gotBody       ProvisionBody
	provID        string
	provErr       error
	provably      bool
}

func (f *fakeFountain) ResolveEnvironment(sel string) (string, error) {
	if f.resolveEnvErr != nil {
		return "", f.resolveEnvErr
	}
	if f.resolveEnvTo != "" {
		return f.resolveEnvTo, nil
	}
	return sel, nil
}

func (f *fakeFountain) ResolveAgent(sel string) (string, error) {
	if f.resolveErr != nil {
		return "", f.resolveErr
	}
	if f.resolveTo != "" {
		return f.resolveTo, nil
	}
	return sel, nil
}

func (f *fakeFountain) Provision(b ProvisionBody) (string, error) {
	f.provably = true
	f.gotBody = b
	if f.provErr != nil {
		return "", f.provErr
	}
	if f.provID != "" {
		return f.provID, nil
	}
	return "ident-1", nil
}

// A valid Nostr secret and its known pubkey (generated once for the test).
const (
	testNsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
	testPub  = "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"
)

func deployReq(cfg string) Request {
	return Request{
		Op:             "deploy",
		Agent:          AgentPayload{Name: "philo", RelayURL: "wss://r", PrivateKeyNsec: testNsec, AuthTag: `["auth","owner"]`},
		ProviderConfig: json.RawMessage(cfg),
	}
}

func TestInfoProtocolVersion(t *testing.T) {
	info := Info()
	if !info.OK || info.ProtocolVersion != 1 || info.Name != "fountain" {
		t.Fatalf("bad info: %+v", info)
	}
	var schema map[string]any
	if err := json.Unmarshal(info.ConfigSchema, &schema); err != nil {
		t.Fatalf("config_schema is not valid JSON: %v", err)
	}
	if _, ok := schema["properties"].(map[string]any)["agent"]; !ok {
		t.Fatalf("config_schema missing the agent selector")
	}
}

func TestDeployProvisionsWithDerivedPubkey(t *testing.T) {
	f := &fakeFountain{resolveTo: "agent-uuid", provID: "buzz-id-1"}
	resp := Deploy(deployReq(`{"agent":"my-agent"}`), f)

	if !resp.OK || resp.AgentID != "buzz-id-1" {
		t.Fatalf("deploy failed: %+v", resp)
	}
	if f.gotBody.Pubkey != testPub {
		t.Fatalf("pubkey = %q, want %q (derived from the nsec)", f.gotBody.Pubkey, testPub)
	}
	if f.gotBody.AgentID != "agent-uuid" {
		t.Fatalf("agent_id = %q, want the resolved id", f.gotBody.AgentID)
	}
	if f.gotBody.PrivateKeyNsec != testNsec {
		t.Fatalf("the nsec must pass through to Fountain, which holds it server-side")
	}
}

// #783: the optional environment selector resolves and rides as environment_id;
// blank means "the agent's own" and sends nothing.
func TestDeployPassesTheEnvironmentSelector(t *testing.T) {
	f := &fakeFountain{resolveTo: "agent-uuid", resolveEnvTo: "env-uuid"}
	resp := Deploy(deployReq(`{"agent":"my-agent","environment":"buzz-env"}`), f)
	if !resp.OK {
		t.Fatalf("deploy failed: %+v", resp)
	}
	if f.gotBody.EnvironmentID != "env-uuid" {
		t.Fatalf("environment_id = %q, want the resolved environment", f.gotBody.EnvironmentID)
	}

	f = &fakeFountain{resolveTo: "agent-uuid"}
	resp = Deploy(deployReq(`{"agent":"my-agent","environment":"  "}`), f)
	if !resp.OK || f.gotBody.EnvironmentID != "" {
		t.Fatalf("a blank environment must send none: %+v / %q", resp, f.gotBody.EnvironmentID)
	}
	if b, _ := json.Marshal(f.gotBody); strings.Contains(string(b), "environment_id") {
		t.Fatalf("environment_id must be omitted when unset: %s", b)
	}
}

// #790: the desktop's respond_to / respond_to_allowlist ride through to
// Fountain, which sets them on the hosted harness. Dropping them left every
// hosted agent owner-only whatever the desktop's record said.
func TestDeployPassesTheAuthorGate(t *testing.T) {
	f := &fakeFountain{}
	req := deployReq(`{"agent":"my-agent"}`)
	req.Agent.RespondTo = "allowlist"
	req.Agent.RespondToAllowlist = []string{" " + testPub + " ", ""}
	resp := Deploy(req, f)
	if !resp.OK {
		t.Fatalf("deploy failed: %+v", resp)
	}
	if f.gotBody.RespondTo != "allowlist" {
		t.Fatalf("respond_to = %q, want allowlist", f.gotBody.RespondTo)
	}
	if len(f.gotBody.RespondToAllowlist) != 1 || f.gotBody.RespondToAllowlist[0] != testPub {
		t.Fatalf("respond_to_allowlist = %v, want the trimmed pubkey only", f.gotBody.RespondToAllowlist)
	}

	// An older desktop that sends neither must not invent a mode: Fountain
	// applies its own owner-only default, so the fields are omitted.
	f = &fakeFountain{}
	resp = Deploy(deployReq(`{"agent":"my-agent"}`), f)
	if !resp.OK {
		t.Fatalf("deploy failed: %+v", resp)
	}
	b, _ := json.Marshal(f.gotBody)
	if strings.Contains(string(b), "respond_to") {
		t.Fatalf("respond_to fields must be omitted when the desktop sent none: %s", b)
	}
}

// The wire shape the desktop actually sends: both fields at the top level of
// "agent", next to the legacy bookkeeping fields, not inside launch.
func TestRequestDecodesTheAuthorGate(t *testing.T) {
	raw := `{"op":"deploy","agent":{"name":"philo","relay_url":"wss://r","private_key_nsec":"x",` +
		`"auth_tag":"t","respond_to":"anyone","respond_to_allowlist":["` + testPub + `"],` +
		`"launch":{"owner_pubkey":"o"}},"provider_config":{"agent":"a"}}`
	var req Request
	if err := json.Unmarshal([]byte(raw), &req); err != nil {
		t.Fatal(err)
	}
	if req.Agent.RespondTo != "anyone" || len(req.Agent.RespondToAllowlist) != 1 {
		t.Fatalf("author gate not decoded: %+v", req.Agent)
	}
}

func TestDeployRefusesAnUnknownEnvironment(t *testing.T) {
	f := &fakeFountain{resolveTo: "agent-uuid", resolveEnvErr: errNoEnv}
	resp := Deploy(deployReq(`{"agent":"my-agent","environment":"nope"}`), f)
	if resp.OK || !strings.Contains(resp.Error, "nope") {
		t.Fatalf("want an in-band refusal naming the environment, got %+v", resp)
	}
	if f.provably {
		t.Fatalf("must not provision when the environment does not resolve")
	}
}

func TestDeployRefusesNoOwner(t *testing.T) {
	req := deployReq(`{"agent":"a"}`)
	req.Agent.AuthTag = ""
	req.Agent.Launch.OwnerPubkey = ""

	f := &fakeFountain{}
	resp := Deploy(req, f)
	if resp.OK || !strings.Contains(resp.Error, "owner") {
		t.Fatalf("expected an owner refusal, got %+v", resp)
	}
	if f.provably {
		t.Fatalf("must refuse before provisioning")
	}
}

func TestDeployAcceptsOwnerPubkeyWithoutAuthTag(t *testing.T) {
	req := deployReq(`{"agent":"a"}`)
	req.Agent.AuthTag = ""
	req.Agent.Launch.OwnerPubkey = "owner-hex"

	resp := Deploy(req, &fakeFountain{})
	if !resp.OK {
		t.Fatalf("an owner pubkey alone should satisfy the owner check: %+v", resp)
	}
}

func TestDeployRefusesRelayMesh(t *testing.T) {
	req := deployReq(`{"agent":"a"}`)
	req.Agent.Provider = "relay-mesh"

	f := &fakeFountain{}
	resp := Deploy(req, f)
	if resp.OK || !strings.Contains(resp.Error, "relay-mesh") {
		t.Fatalf("expected a relay-mesh refusal, got %+v", resp)
	}
	if f.provably {
		t.Fatalf("must refuse before provisioning")
	}
}

func TestDeployRequiresAgentSelector(t *testing.T) {
	resp := Deploy(deployReq(`{}`), &fakeFountain{})
	if resp.OK || !strings.Contains(resp.Error, "agent") {
		t.Fatalf("expected a missing-agent error, got %+v", resp)
	}
}

func TestDeployRejectsABadKey(t *testing.T) {
	req := deployReq(`{"agent":"a"}`)
	req.Agent.PrivateKeyNsec = "not-a-key"
	resp := Deploy(req, &fakeFountain{})
	if resp.OK || !strings.Contains(resp.Error, "pubkey") {
		t.Fatalf("expected a key-derivation error, got %+v", resp)
	}
}

// ADR 0023: the optional sandbox mode rides as sandbox_mode; blank sends
// nothing; anything else is refused before Fountain is asked.
func TestDeployPassesTheSandboxMode(t *testing.T) {
	f := &fakeFountain{resolveTo: "agent-uuid"}
	resp := Deploy(deployReq(`{"agent":"my-agent","sandbox_mode":"persistent"}`), f)
	if !resp.OK {
		t.Fatalf("deploy failed: %+v", resp)
	}
	if f.gotBody.SandboxMode != "persistent" {
		t.Fatalf("sandbox_mode = %q, want persistent", f.gotBody.SandboxMode)
	}

	f = &fakeFountain{resolveTo: "agent-uuid"}
	resp = Deploy(deployReq(`{"agent":"my-agent","sandbox_mode":" "}`), f)
	if !resp.OK || f.gotBody.SandboxMode != "" {
		t.Fatalf("blank sandbox_mode: ok=%v body=%q, want ok and nothing sent", resp.OK, f.gotBody.SandboxMode)
	}

	f = &fakeFountain{resolveTo: "agent-uuid"}
	resp = Deploy(deployReq(`{"agent":"my-agent","sandbox_mode":"forever"}`), f)
	if resp.OK || f.gotBody.AgentID != "" {
		t.Fatalf("bad sandbox_mode: ok=%v provisioned=%q, want a refusal before any call", resp.OK, f.gotBody.AgentID)
	}
}
