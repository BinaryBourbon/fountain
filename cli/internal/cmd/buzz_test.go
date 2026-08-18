package cmd

import "testing"

func TestBuzzAccessBody(t *testing.T) {
	body, err := buzzAccessBody("anyone", "", false)
	if err != nil || body["respond_to"] != "anyone" {
		t.Fatalf("mode alone: %v %v", body, err)
	}
	if _, has := body["respond_to_allowlist"]; has {
		t.Fatalf("an unset --allowlist must not be sent (it would clear the server's list): %v", body)
	}

	body, err = buzzAccessBody("allowlist", " aa , bb,, ", true)
	if err != nil {
		t.Fatal(err)
	}
	if got := body["respond_to_allowlist"].([]string); len(got) != 2 || got[0] != "aa" || got[1] != "bb" {
		t.Fatalf("allowlist not split/trimmed: %v", got)
	}

	// An explicit empty --allowlist sends [] so the server can clear it (or
	// refuse it in allowlist mode) — that is a decision, not an omission.
	body, _ = buzzAccessBody("", "", true)
	if got := body["respond_to_allowlist"].([]string); len(got) != 0 {
		t.Fatalf("empty --allowlist must send []: %v", got)
	}

	if _, err := buzzAccessBody("everyone", "", false); err == nil {
		t.Fatal("an unknown mode must be a usage error, not a 422")
	}
	if _, err := buzzAccessBody("", "", false); err == nil {
		t.Fatal("no flags must be a usage error")
	}
}

func TestBuzzAccessLabel(t *testing.T) {
	if got := buzzAccessLabel(map[string]any{"respond_to": "anyone"}); got != "anyone" {
		t.Fatal(got)
	}
	if got := buzzAccessLabel(map[string]any{"respond_to": "allowlist", "respond_to_allowlist": []any{"a", "b"}}); got != "allowlist(2)" {
		t.Fatal(got)
	}
}
