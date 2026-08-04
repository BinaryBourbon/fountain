package secrets

import (
	"errors"
	"strings"
	"testing"
)

func TestBitwardenRead(t *testing.T) {
	t.Run("extracts value from JSON output", func(t *testing.T) {
		dir := fakeCLI(t, "bws", `printf '{"id":"u-u-i-d","key":"DB_URL","value":"postgres://x"}'`)
		got, err := (&Bitwarden{}).Read("bws://u-u-i-d")
		if err != nil {
			t.Fatal(err)
		}
		if got != "postgres://x" {
			t.Fatalf("Read = %q", got)
		}
		if args := recordedArgs(t, dir, "bws"); args != "secret get u-u-i-d" {
			t.Fatalf("bws invoked with %q", args)
		}
	})

	t.Run("empty value string is returned as-is", func(t *testing.T) {
		fakeCLI(t, "bws", `printf '{"value":""}'`)
		got, err := (&Bitwarden{}).Read("bws://u")
		if err != nil || got != "" {
			t.Fatalf("Read = %q, %v; want empty string, nil", got, err)
		}
	})

	t.Run("rejects ref without the bws:// prefix", func(t *testing.T) {
		_, err := (&Bitwarden{}).Read("op://nope")
		if !errors.Is(err, errBwsInvalidRef) {
			t.Fatalf("err = %v, want errBwsInvalidRef", err)
		}
	})

	t.Run("rejects ref with empty uuid", func(t *testing.T) {
		_, err := (&Bitwarden{}).Read("bws://")
		if !errors.Is(err, errBwsEmptyRef) {
			t.Fatalf("err = %v, want errBwsEmptyRef", err)
		}
		if msg := (&Bitwarden{}).FormatError(err); !strings.Contains(msg, "missing the UUID") {
			t.Fatalf("FormatError = %q", msg)
		}
	})

	t.Run("not installed", func(t *testing.T) {
		noCLI(t)
		_, err := (&Bitwarden{}).Read("bws://u")
		if !errors.Is(err, errBwsNotInstalled) {
			t.Fatalf("err = %v, want errBwsNotInstalled", err)
		}
	})

	t.Run("non-zero exit carries output", func(t *testing.T) {
		fakeCLI(t, "bws", `echo '404: secret not found'; exit 1`)
		_, err := (&Bitwarden{}).Read("bws://u")
		if err == nil {
			t.Fatal("want error")
		}
		if msg := (&Bitwarden{}).FormatError(err); msg != "404: secret not found" {
			t.Fatalf("FormatError = %q", msg)
		}
	})

	t.Run("non-JSON output", func(t *testing.T) {
		fakeCLI(t, "bws", `printf 'not json'`)
		_, err := (&Bitwarden{}).Read("bws://u")
		if err == nil {
			t.Fatal("want error")
		}
		if msg := (&Bitwarden{}).FormatError(err); !strings.Contains(msg, "could not parse") {
			t.Fatalf("FormatError = %q", msg)
		}
	})

	t.Run("JSON without a value field", func(t *testing.T) {
		fakeCLI(t, "bws", `printf '{"id":"u"}'`)
		_, err := (&Bitwarden{}).Read("bws://u")
		if err == nil {
			t.Fatal("want error")
		}
		if msg := (&Bitwarden{}).FormatError(err); !strings.Contains(msg, "no string `value` field") {
			t.Fatalf("FormatError = %q", msg)
		}
	})
}
