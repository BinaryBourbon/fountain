package cmd

import (
	"encoding/json"
	"testing"
)

func TestRunExecutionLimitsPreserveExplicitZero(t *testing.T) {
	command, _, err := rootCmd.Find([]string{"run"})
	if err != nil {
		t.Fatal(err)
	}
	names := []string{"wall-time-seconds", "max-model-turns", "max-estimated-cost-usd"}
	for _, name := range names {
		flag := command.Flags().Lookup(name)
		if flag == nil {
			t.Fatalf("missing flag %s", name)
		}
		old, changed := flag.Value.String(), flag.Changed
		t.Cleanup(func() { _ = flag.Value.Set(old); flag.Changed = changed })
		_ = flag.Value.Set(flag.DefValue)
		flag.Changed = false
	}
	if len(executionLimitsFromFlags(command)) != 0 {
		t.Fatal("omission emitted limits")
	}
	if err := command.Flags().Set("wall-time-seconds", "0"); err != nil {
		t.Fatal(err)
	}
	if err := command.Flags().Set("max-estimated-cost-usd", "0.25"); err != nil {
		t.Fatal(err)
	}
	payload, err := json.Marshal(executionLimitsFromFlags(command))
	if err != nil {
		t.Fatal(err)
	}
	var wire map[string]any
	if err := json.Unmarshal(payload, &wire); err != nil {
		t.Fatal(err)
	}
	if value, ok := wire["wall_time_seconds"]; !ok || value != float64(0) {
		t.Fatalf("explicit zero disappeared: %s", payload)
	}
	if wire["max_estimated_cost_usd"] != 0.25 {
		t.Fatalf("cost lost its fraction: %s", payload)
	}
	if _, ok := wire["max_model_turns"]; ok {
		t.Fatalf("omitted field was emitted: %s", payload)
	}
}
