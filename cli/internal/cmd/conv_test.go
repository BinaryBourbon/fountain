package cmd

import (
	"errors"
	"testing"
)

// handleStageEvent is the terminal-condition decision for the stream loop.
// The `data` maps below mirror the SSE payload write_event renders
// (conversation_controller.ex): stage/state at the top level, and the
// publish_stage meta as a JSON-encoded STRING under "data"
// (conversation_server.ex publishes `turn`/`done` with exit_code, turn_id,
// turn_number).
func TestHandleStageEvent(t *testing.T) {
	cases := []struct {
		name     string
		data     map[string]any
		terminal bool
		wantErr  error
	}{
		{
			name: "turn done exit 0 is a clean terminal",
			data: map[string]any{
				"stage": "turn", "state": "done",
				"data": `{"exit_code":0,"turn_id":"t-1","turn_number":2}`,
			},
			terminal: true,
			wantErr:  nil,
		},
		{
			name: "turn done with non-zero exit_code fails",
			data: map[string]any{
				"stage": "turn", "state": "done",
				"data": `{"exit_code":2,"turn_id":"t-1","turn_number":2}`,
			},
			terminal: true,
			wantErr:  errTurnFailed,
		},
		{
			name:     "turn done without payload defaults to clean",
			data:     map[string]any{"stage": "turn", "state": "done"},
			terminal: true,
			wantErr:  nil,
		},
		{
			name:     "turn failed",
			data:     map[string]any{"stage": "turn", "state": "failed", "data": "{}"},
			terminal: true,
			wantErr:  errTurnFailed,
		},
		{
			name: "provision failed",
			data: map[string]any{
				"stage": "provision", "state": "failed",
				"data": `{"reason":"provision deadline exceeded"}`,
			},
			terminal: true,
			wantErr:  errProvisionFailed,
		},
		{
			name:     "terminate done is a clean terminal",
			data:     map[string]any{"stage": "terminate", "state": "done", "data": "{}"},
			terminal: true,
			wantErr:  nil,
		},
		{
			name:     "provision started is not terminal",
			data:     map[string]any{"stage": "provision", "state": "started", "data": "{}"},
			terminal: false,
			wantErr:  nil,
		},
		{
			name:     "setup failed is not terminal (a turn may still run)",
			data:     map[string]any{"stage": "setup", "state": "failed", "data": `{"exit_code":1}`},
			terminal: false,
			wantErr:  nil,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			terminal, err := handleStageEvent(tc.data)
			if terminal != tc.terminal {
				t.Errorf("terminal: got %v, want %v", terminal, tc.terminal)
			}
			if tc.wantErr == nil && err != nil {
				t.Errorf("err: got %v, want nil", err)
			}
			if tc.wantErr != nil && !errors.Is(err, tc.wantErr) {
				t.Errorf("err: got %v, want %v", err, tc.wantErr)
			}
		})
	}
}

// lastEventIDIn extracts the stream head from a `?wait=false` drain, which is
// what lets conv prompt / conv stream skip the history replay (#398).
func TestLastEventIDIn(t *testing.T) {
	drained := "id: 1\nevent: stage\ndata: {\"stage\":\"provision\",\"state\":\"done\"}\n\n" +
		"id: 2\nevent: output\ndata: {\"stream\":\"stdout\",\"data\":\"hi\"}\n\n" +
		"id: 3\nevent: stage\ndata: {\"stage\":\"turn\",\"state\":\"done\"}\n\n"

	if got := lastEventIDIn(drained); got != "3" {
		t.Errorf("head: got %q, want \"3\"", got)
	}
	if got := lastEventIDIn(""); got != "" {
		t.Errorf("empty drain should have no head, got %q", got)
	}
	// A body whose final event lacks the trailing blank line still counts.
	if got := lastEventIDIn("id: 7\nevent: stage\ndata: {}"); got != "7" {
		t.Errorf("unterminated final event: got %q, want \"7\"", got)
	}
	// Heartbeat comments carry no id and must not confuse the head.
	if got := lastEventIDIn(": heartbeat\n\n"); got != "" {
		t.Errorf("heartbeat-only drain should have no head, got %q", got)
	}
}
