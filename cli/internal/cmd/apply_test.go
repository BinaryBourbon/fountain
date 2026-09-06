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
	grouped := map[string][]*manifest.Doc{
		"Environment": {doc("Environment", "proj", map[string]any{
			"setup_script": "echo hi",
			"secrets":      map[string]any{"TOKEN": "t0"},
			"user_id":      "someone-else",
			"created_by":   "mallory",
			"id":           "forced-id",
		})},
		"Vault": {doc("Vault", "alice", nil)},
		"Agent": {doc("Agent", "researcher", map[string]any{
			"runtime":     "claude",
			"environment": "proj",
		})},
		"Teammate": {doc("Teammate", "Ada", map[string]any{"agent": "researcher"})},
		"Schedule": {doc("Schedule", "standup", map[string]any{"teammate": "Ada", "cron": "@daily"})},
		"Webhook":  {doc("Webhook", "ci", map[string]any{"url": "https://example.com/h"})},
	}

	// Payload order is the six kinds in reconciliation order, whatever order
	// the manifest listed them in.
	got := buildApplyPayload(grouped)

	if len(got) != 6 {
		t.Fatalf("want 6 resources, got %d", len(got))
	}
	wantKinds := []string{"Environment", "Vault", "Agent", "Teammate", "Schedule", "Webhook"}
	for i, want := range wantKinds {
		if got[i].Kind != want {
			t.Fatalf("resource %d: want kind %q, got %q", i, want, got[i].Kind)
		}
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

func TestGroupDocsBucketsEveryKind(t *testing.T) {
	docs := []*manifest.Doc{
		doc("Webhook", "ci", nil),
		doc("Agent", "a", nil),
		doc("Cluster", "nope", nil),
		doc("Teammate", "Ada", nil),
		doc("Schedule", "standup", nil),
		doc("Environment", "e", nil),
		doc("Vault", "v", nil),
	}

	grouped, unknown := groupDocs(docs)

	for _, kind := range []string{"Environment", "Vault", "Agent", "Teammate", "Schedule", "Webhook"} {
		if len(grouped[kind]) != 1 {
			t.Errorf("%s: want 1 doc, got %d", kind, len(grouped[kind]))
		}
	}
	if len(unknown) != 1 || unknown[0].Kind != "Cluster" {
		t.Errorf("an unsupported kind must come back as unknown, got %v", unknown)
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
			{Kind: "Teammate", Name: "Ada", Action: "unchanged"},
			{Kind: "Webhook", Name: "ci", Action: "created", Secret: "whsec_x"},
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
