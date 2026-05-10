package sse

import "testing"

func TestFeed_LeavesPartialEvent(t *testing.T) {
	events, leftover := Feed("event: stage\ndata: \"hi\"\n\nevent: ou")
	if len(events) != 1 {
		t.Fatalf("events: %d", len(events))
	}
	if events[0].Event != "stage" {
		t.Fatalf("event: %q", events[0].Event)
	}
	if leftover != "event: ou" {
		t.Fatalf("leftover: %q", leftover)
	}
}

func TestFeed_DecodesJSONData(t *testing.T) {
	events, _ := Feed(`event: stage
data: {"stage":"turn","state":"done"}

`)
	if len(events) != 1 {
		t.Fatalf("events: %d", len(events))
	}
	m, ok := events[0].Data.(map[string]any)
	if !ok {
		t.Fatalf("data not map: %T", events[0].Data)
	}
	if m["stage"] != "turn" || m["state"] != "done" {
		t.Fatalf("data: %v", m)
	}
}

func TestFeed_FallsBackToRawString(t *testing.T) {
	events, _ := Feed("data: not json\n\n")
	if len(events) != 1 {
		t.Fatalf("events: %d", len(events))
	}
	s, ok := events[0].Data.(string)
	if !ok || s != "not json" {
		t.Fatalf("data: %v", events[0].Data)
	}
}

func TestFeed_IgnoresHeartbeat(t *testing.T) {
	events, _ := Feed(": keep-alive\n\n")
	if len(events) != 0 {
		t.Fatalf("events: %d", len(events))
	}
}

func TestFeed_ParsesIDAsInt(t *testing.T) {
	events, _ := Feed("id: 42\nevent: x\ndata: ok\n\n")
	if len(events) != 1 {
		t.Fatalf("events: %d", len(events))
	}
	if events[0].ID != 42 {
		t.Fatalf("id: %d", events[0].ID)
	}
}
