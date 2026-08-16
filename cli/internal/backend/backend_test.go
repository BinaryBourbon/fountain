package backend

import (
	"encoding/json"
	"strings"
	"testing"
)

// fakeFountain records calls and returns canned results.
type fakeFountain struct {
	resolveTo  string
	resolveErr error
	gotBody    ProvisionBody
	provID     string
	provErr    error
	provably   bool
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
