package secrets

import (
	"errors"
	"strings"
	"testing"
)

func TestOnePasswordRead(t *testing.T) {
	t.Run("returns stdout verbatim on success", func(t *testing.T) {
		dir := fakeCLI(t, "op", `printf 's3cret'`)
		got, err := (&OnePassword{}).Read("op://vault/item/field")
		if err != nil {
			t.Fatal(err)
		}
		if got != "s3cret" {
			t.Fatalf("Read = %q, want s3cret", got)
		}
		if args := recordedArgs(t, dir, "op"); args != "read --no-newline op://vault/item/field" {
			t.Fatalf("op invoked with %q", args)
		}
	})

	t.Run("not installed", func(t *testing.T) {
		noCLI(t)
		_, err := (&OnePassword{}).Read("op://vault/item/field")
		if !errors.Is(err, errOpNotInstalled) {
			t.Fatalf("err = %v, want errOpNotInstalled", err)
		}
		if msg := (&OnePassword{}).FormatError(err); !strings.Contains(msg, "not on PATH") {
			t.Fatalf("FormatError = %q", msg)
		}
	})

	t.Run("non-zero exit carries trimmed combined output", func(t *testing.T) {
		fakeCLI(t, "op", `echo 'item not found' >&2; exit 1`)
		_, err := (&OnePassword{}).Read("op://vault/missing/field")
		if err == nil {
			t.Fatal("want error")
		}
		if msg := (&OnePassword{}).FormatError(err); msg != "item not found" {
			t.Fatalf("FormatError = %q, want the CLI's stderr", msg)
		}
	})

	t.Run("non-zero exit with no output", func(t *testing.T) {
		fakeCLI(t, "op", `exit 3`)
		_, err := (&OnePassword{}).Read("op://vault/item/field")
		if err == nil {
			t.Fatal("want error")
		}
		if msg := (&OnePassword{}).FormatError(err); msg != "op exited non-zero with no output" {
			t.Fatalf("FormatError = %q", msg)
		}
	})
}

func TestOnePasswordFormatErrorFallback(t *testing.T) {
	if msg := (&OnePassword{}).FormatError(errors.New("boom")); msg != "boom" {
		t.Fatalf("FormatError = %q, want boom", msg)
	}
}
