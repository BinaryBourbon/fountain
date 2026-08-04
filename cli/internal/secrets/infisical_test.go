package secrets

import (
	"errors"
	"strings"
	"testing"
)

func TestParseInfisical(t *testing.T) {
	cases := []struct {
		name    string
		rest    string
		want    infisicalParts
		wantErr string
	}{
		{
			name: "project/env/name",
			rest: "proj123/dev/API_KEY",
			want: infisicalParts{Project: "proj123", Env: "dev", Path: "/", Name: "API_KEY"},
		},
		{
			name: "empty project falls through to CLI resolution",
			rest: "/dev/API_KEY",
			want: infisicalParts{Project: "", Env: "dev", Path: "/", Name: "API_KEY"},
		},
		{
			name: "single path segment",
			rest: "proj/staging/backend/DB_URL",
			want: infisicalParts{Project: "proj", Env: "staging", Path: "/backend", Name: "DB_URL"},
		},
		{
			name: "nested path segments",
			rest: "proj/prod/backend/db/PASSWORD",
			want: infisicalParts{Project: "proj", Env: "prod", Path: "/backend/db", Name: "PASSWORD"},
		},
		{name: "too few segments", rest: "dev/API_KEY", wantErr: "at least env and name"},
		{name: "empty env", rest: "proj//API_KEY", wantErr: "at least env and name"},
		{name: "empty name", rest: "proj/dev/", wantErr: "at least env and name"},
		{name: "empty name after path", rest: "proj/dev/backend/", wantErr: "missing secret name"},
		{name: "empty path segment", rest: "proj/dev//NAME", wantErr: "empty path segment"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseInfisical(tc.rest)
			if tc.wantErr != "" {
				if err == nil {
					t.Fatalf("parseInfisical(%q) = %+v, want error", tc.rest, got)
				}
				if !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("err = %v, want it to mention %q", err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got != tc.want {
				t.Fatalf("parseInfisical(%q) = %+v, want %+v", tc.rest, got, tc.want)
			}
		})
	}
}

func TestInfisicalRead(t *testing.T) {
	t.Run("builds the CLI invocation and trims the trailing newline", func(t *testing.T) {
		dir := fakeCLI(t, "infisical", `echo 'plain-value'`)
		got, err := (&Infisical{}).Read("infisical://proj/dev/backend/API_KEY")
		if err != nil {
			t.Fatal(err)
		}
		if got != "plain-value" {
			t.Fatalf("Read = %q", got)
		}
		want := "secrets get API_KEY --env=dev --path=/backend --plain --projectId=proj"
		if args := recordedArgs(t, dir, "infisical"); args != want {
			t.Fatalf("infisical invoked with %q, want %q", args, want)
		}
	})

	t.Run("omits --projectId when project segment is empty", func(t *testing.T) {
		dir := fakeCLI(t, "infisical", `echo v`)
		if _, err := (&Infisical{}).Read("infisical:///dev/API_KEY"); err != nil {
			t.Fatal(err)
		}
		if args := recordedArgs(t, dir, "infisical"); strings.Contains(args, "--projectId") {
			t.Fatalf("infisical invoked with %q, want no --projectId", args)
		}
	})

	t.Run("invalid ref fails before any exec", func(t *testing.T) {
		noCLI(t)
		_, err := (&Infisical{}).Read("infisical://proj")
		var ir *infisicalInvalidRef
		if !errors.As(err, &ir) {
			t.Fatalf("err = %v, want infisicalInvalidRef", err)
		}
	})

	t.Run("not installed", func(t *testing.T) {
		noCLI(t)
		_, err := (&Infisical{}).Read("infisical://proj/dev/API_KEY")
		if !errors.Is(err, errInfisicalNotInstalled) {
			t.Fatalf("err = %v, want errInfisicalNotInstalled", err)
		}
		if msg := (&Infisical{}).FormatError(err); !strings.Contains(msg, "not on PATH") {
			t.Fatalf("FormatError = %q", msg)
		}
	})

	t.Run("non-zero exit carries output", func(t *testing.T) {
		fakeCLI(t, "infisical", `echo 'secret not found'; exit 1`)
		_, err := (&Infisical{}).Read("infisical://proj/dev/API_KEY")
		if err == nil {
			t.Fatal("want error")
		}
		if msg := (&Infisical{}).FormatError(err); msg != "secret not found" {
			t.Fatalf("FormatError = %q", msg)
		}
	})
}
