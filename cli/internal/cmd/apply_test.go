package cmd

import (
	"reflect"
	"testing"

	"github.com/BinaryBourbon/fountain/cli/internal/manifest"
)

func doc(kind, name string, spec map[string]any) *manifest.Doc {
	return &manifest.Doc{
		APIVersion: "fountain/v1",
		Kind:       kind,
		Metadata:   map[string]any{"name": name},
		Spec:       spec,
	}
}

func TestBuildApplyPayloadOrdersAndStrips(t *testing.T) {
	envs := []*manifest.Doc{doc("Environment", "proj", map[string]any{
		"setup_script": "echo hi",
		"secrets":      map[string]any{"TOKEN": "t0"},
		"user_id":      "someone-else",
		"created_by":   "mallory",
		"id":           "forced-id",
	})}
	vaults := []*manifest.Doc{doc("Vault", "alice", nil)}
	agents := []*manifest.Doc{doc("Agent", "researcher", map[string]any{
		"runtime":     "claude",
		"environment": "proj",
	})}

	// Payload order is envs, vaults, agents regardless of manifest order.
	got := buildApplyPayload(envs, vaults, agents)

	if len(got) != 3 {
		t.Fatalf("want 3 resources, got %d", len(got))
	}
	if got[0].Kind != "Environment" || got[1].Kind != "Vault" || got[2].Kind != "Agent" {
		t.Fatalf("wrong kind order: %v, %v, %v", got[0].Kind, got[1].Kind, got[2].Kind)
	}

	env := got[0]
	if env.Name != "proj" {
		t.Fatalf("want name proj, got %q", env.Name)
	}
	for _, k := range []string{"id", "user_id", "created_by"} {
		if _, ok := env.Spec[k]; ok {
			t.Errorf("ownership field %q must be stripped from spec", k)
		}
	}
	// Secrets stay inline — the server splits them out and encrypts.
	wantSecrets := map[string]any{"TOKEN": "t0"}
	if !reflect.DeepEqual(env.Spec["secrets"], wantSecrets) {
		t.Errorf("want inline secrets %v, got %v", wantSecrets, env.Spec["secrets"])
	}

	// The environment name reference is passed through for server-side resolution.
	if got[2].Spec["environment"] != "proj" {
		t.Errorf("agent environment reference must be preserved, got %v", got[2].Spec["environment"])
	}

	// A nil spec still yields a non-nil map so the JSON encodes as {}.
	if got[1].Spec == nil {
		t.Errorf("nil spec must be sent as an empty object")
	}
}

func TestRenderApplyResultsFailureDetection(t *testing.T) {
	cases := []struct {
		name    string
		results []applyResult
		want    bool
	}{
		{"all ok", []applyResult{
			{Kind: "Environment", Name: "e", Action: "created"},
			{Kind: "Agent", Name: "a", Action: "updated"},
		}, false},
		{"resource error", []applyResult{
			{Kind: "Agent", Name: "a", Action: "error", Errors: map[string]any{"model": []any{"can't be blank"}}},
		}, true},
		{"secret error", []applyResult{
			{Kind: "Vault", Name: "v", Action: "created", Secrets: []applySecretResult{
				{Key: "GH", Action: "error"},
			}},
		}, true},
	}
	for _, tc := range cases {
		if got := renderApplyResults(tc.results); got != tc.want {
			t.Errorf("%s: anyFailed = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestFormatResultErrors(t *testing.T) {
	got := formatResultErrors(map[string]any{
		"model":   []any{"can't be blank"},
		"runtime": []any{"is invalid"},
	})
	want := "model: [can't be blank]; runtime: [is invalid]"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if formatResultErrors(nil) != "apply failed" {
		t.Errorf("nil errors should fall back to generic message")
	}
}
