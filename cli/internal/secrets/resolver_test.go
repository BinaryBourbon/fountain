package secrets

import "testing"

func TestForValue(t *testing.T) {
	cases := []struct {
		name  string
		value string
		want  string // expected prefix of the matched resolver, "" for nil
	}{
		{"op ref", "op://vault/item/field", "op://"},
		{"bws ref", "bws://0193bf1d-0000-7000-8000-000000000000", "bws://"},
		{"infisical ref", "infisical://proj/dev/API_KEY", "infisical://"},
		{"plain value", "hunter2", ""},
		{"empty value", "", ""},
		{"scheme-like but unknown", "vault://foo", ""},
		{"prefix must anchor at start", "x op://vault/item/field", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ForValue(tc.value, Default)
			if tc.want == "" {
				if got != nil {
					t.Fatalf("ForValue(%q) = %v, want nil", tc.value, got.Prefix())
				}
				return
			}
			if got == nil {
				t.Fatalf("ForValue(%q) = nil, want resolver for %s", tc.value, tc.want)
			}
			if got.Prefix() != tc.want {
				t.Fatalf("ForValue(%q).Prefix() = %s, want %s", tc.value, got.Prefix(), tc.want)
			}
		})
	}
}

func TestForValueEmptyRegistry(t *testing.T) {
	if got := ForValue("op://vault/item/field", nil); got != nil {
		t.Fatalf("ForValue with empty registry = %v, want nil", got)
	}
}
