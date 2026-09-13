package cmd

import (
	"os"
	"strings"
	"testing"
)

func TestPrintOAuthClientOrigins(t *testing.T) {
	for _, tt := range []struct {
		name     string
		uris     []string
		origins  []string
		loopback bool
	}{
		{"localhost", []string{"http://localhost:5173/callback"}, []string{"http://localhost:5173"}, true},
		{"uppercase localhost", []string{"https://LOCALHOST/callback"}, []string{"https://localhost"}, true},
		{"IPv4", []string{"http://127.0.0.1:8080/callback"}, []string{"http://127.0.0.1:8080"}, true},
		{"IPv6", []string{"http://[::1]:8080/callback"}, []string{"http://[::1]:8080"}, true},
		{"IPv6 without port", []string{"http://[::1]/callback"}, []string{"http://[::1]"}, true},
		{"mixed origins", []string{"https://notes.test/callback", "http://localhost:5173/callback", "http://127.0.0.1:8080/callback"}, []string{"https://notes.test", "http://localhost:5173", "http://127.0.0.1:8080"}, true},
		{"remote", []string{"https://notes.test/callback"}, []string{"https://notes.test"}, false},
		{"localhost subdomain", []string{"https://localhost.notes.test/callback"}, []string{"https://localhost.notes.test"}, false},
		{"loopback in path", []string{"https://notes.test/localhost"}, []string{"https://notes.test"}, false},
		{"other IPv4 loopback", []string{"https://127.0.0.2/callback"}, []string{"https://127.0.0.2"}, false},
		{"malformed", []string{"http://[::1"}, nil, false},
		{"relative", []string{"localhost/callback"}, nil, false},
		{"empty", nil, nil, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			stdout, err := os.CreateTemp(t.TempDir(), "stdout")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { stdout.Close() })
			original := os.Stdout
			os.Stdout = stdout
			t.Cleanup(func() { os.Stdout = original })

			printOAuthClient(oauthClient{RedirectURIs: tt.uris, Origins: tt.origins})

			got, err := os.ReadFile(stdout.Name())
			if err != nil {
				t.Fatal(err)
			}
			want := "origins:       " + strings.Join(tt.origins, ", ")
			if tt.loopback {
				want += " (loopback: any port)"
			}
			lines := strings.Split(strings.TrimSuffix(string(got), "\n"), "\n")
			if last := lines[len(lines)-1]; last != want {
				t.Errorf("origins line = %q, want %q", last, want)
			}
		})
	}
}
