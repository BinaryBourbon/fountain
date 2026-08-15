package acp

import "testing"

func toolCallLine(sessionID string) string {
	return `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"` + sessionID + `",` +
		`"update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Edit lib/foo.ex","kind":"edit",` +
		`"status":"pending","locations":[{"path":"/workspace/lib/foo.ex","line":42}]}}}`
}

// #705. The paths are the sandbox's, on a machine that is not the developer's.
// An editor that opens them either shows the wrong file or fails silently, and
// either way the developer concludes the agent is editing their project.
func TestToolCallLocationsDoNotReachTheEditor(t *testing.T) {
	api := &fakeAPI{
		events: []Event{
			{Kind: "output", Stream: "acp", Data: toolCallLine("sprite-session")},
			stageEvent("turn", "done", `{"stop_reason":"end_turn"}`),
		},
	}
	a, notifier := promptAgent(t, api)

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))

	if len(notifier.params) != 1 {
		t.Fatalf("want one forwarded update, got %d", len(notifier.params))
	}
	update := notifier.params[0]["update"].(map[string]any)

	if _, present := update["locations"]; present {
		t.Error("locations were forwarded — an editor will try to open a path that is not on this machine")
	}
}

// Removed from where an editor acts on them, kept where a future client could
// use them: read-through is a separate decision, not a reason to lose the data.
func TestSandboxLocationsAreKeptUnderMeta(t *testing.T) {
	api := &fakeAPI{
		events: []Event{
			{Kind: "output", Stream: "acp", Data: toolCallLine("sprite-session")},
			stageEvent("turn", "done", `{"stop_reason":"end_turn"}`),
		},
	}
	a, notifier := promptAgent(t, api)

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))

	update := notifier.params[0]["update"].(map[string]any)
	meta, ok := update["_meta"].(map[string]any)
	if !ok {
		t.Fatalf("no _meta on the forwarded update: %v", update)
	}
	locations, ok := meta[MetaSandboxLocations].([]any)
	if !ok || len(locations) != 1 {
		t.Fatalf("_meta[%s] = %v, want the one location", MetaSandboxLocations, meta[MetaSandboxLocations])
	}
	first := locations[0].(map[string]any)
	if first["path"] != "/workspace/lib/foo.ex" || first["line"] != float64(42) {
		t.Errorf("location = %v, want the sandbox path and line preserved intact", first)
	}
}

// Everything else about the tool call still has to arrive: the title is what
// the human reads, and it usually names the file anyway.
func TestTheRestOfTheToolCallIsUntouched(t *testing.T) {
	api := &fakeAPI{
		events: []Event{
			{Kind: "output", Stream: "acp", Data: toolCallLine("sprite-session")},
			stageEvent("turn", "done", `{"stop_reason":"end_turn"}`),
		},
	}
	a, notifier := promptAgent(t, api)

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))

	update := notifier.params[0]["update"].(map[string]any)
	for key, want := range map[string]any{
		"sessionUpdate": "tool_call",
		"toolCallId":    "t1",
		"title":         "Edit lib/foo.ex",
		"kind":          "edit",
		"status":        "pending",
	} {
		if update[key] != want {
			t.Errorf("update[%q] = %v, want %v", key, update[key], want)
		}
	}
}

// An update with no locations must pass through without growing an empty
// `_meta` — most updates are message chunks, and every one of them would carry
// the noise.
func TestUpdatesWithoutLocationsAreNotRewritten(t *testing.T) {
	api := &fakeAPI{
		events: []Event{
			{Kind: "output", Stream: "acp", Data: acpLine("sprite-session", "hello")},
			stageEvent("turn", "done", `{"stop_reason":"end_turn"}`),
		},
	}
	a, notifier := promptAgent(t, api)

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))

	update := notifier.params[0]["update"].(map[string]any)
	if _, present := update["_meta"]; present {
		t.Errorf("an update with no locations grew a _meta: %v", update)
	}
}
