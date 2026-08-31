package cmd

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/BinaryBourbon/fountain/cli/internal/credentials"
)

// TestAuthLoginAPIKeyWritesCredentials is the fix for #1305: an account
// created with "Sign up with GitHub" has no password, so `auth login`'s
// email + password exchange can never work for it. `auth login --api-key`
// reads a pasted key from stdin, verifies it against GET /api/auth/me and
// writes it to the credentials file.
func TestAuthLoginAPIKeyWritesCredentials(t *testing.T) {
	const key = "ftn_test_1111111111111111"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/auth/me" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			http.NotFound(w, r)
			return
		}
		if got := r.Header.Get("Authorization"); got != "Bearer "+key {
			t.Errorf("Authorization = %q, want the pasted key", got)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		// Byte-for-byte the shape of FountainWeb.AuthMeController.show/2:
		// a flat object, no `data` envelope.
		_, _ = w.Write([]byte(`{
			"id": "0198c9a2-1111-7222-8333-444455556666",
			"email": "goat@example.com",
			"role": "user"
		}`))
	}))
	defer srv.Close()

	t.Setenv("FOUNTAIN_BASE_URL", srv.URL)
	t.Setenv("FOUNTAIN_PROFILE", "")

	credsPath := filepath.Join(t.TempDir(), "credentials")
	credentials.SetPathOverride(credsPath)
	t.Cleanup(func() { credentials.SetPathOverride("") })

	restore := stdinFrom(t, key+"\n")
	defer restore()

	if err := authLoginAPIKey(); err != nil {
		t.Fatalf("authLoginAPIKey: %v", err)
	}

	content, err := os.ReadFile(credsPath)
	if err != nil {
		t.Fatalf("credentials file was not written: %v", err)
	}
	attrs := credentials.ParseAll(string(content))["default"]
	if attrs["api_key"] != key {
		t.Errorf("saved api_key = %q, want %q", attrs["api_key"], key)
	}
	if attrs["base_url"] != srv.URL {
		t.Errorf("saved base_url = %q, want %q", attrs["base_url"], srv.URL)
	}
}

// A mispasted key must fail at login time, not on the next command — and it
// must not be written to the credentials file.
func TestAuthLoginAPIKeyRejectsBadKey(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"Invalid API key"}`))
	}))
	defer srv.Close()

	_, err := fetchAuthMe(srv.URL, "ftn_wrong")
	if err == nil {
		t.Fatal("fetchAuthMe accepted a key the server rejected")
	}
	if !strings.Contains(err.Error(), "401") {
		t.Errorf("error %q does not name the 401", err)
	}
}

// TestAuthLoginDeviceWritesCredentials drives the whole RFC-8628-shaped flow
// (#1305) against the exact JSON FountainWeb.DeviceAuthController renders:
// start a grant, poll through authorization_pending and slow_down, collect
// the key once "the browser approved", and write the credentials file.
func TestAuthLoginDeviceWritesCredentials(t *testing.T) {
	const key = "ftn_test_2222222222222222"

	var polls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/auth/device":
			// interval 0 keeps the test's poll loop fast.
			_, _ = w.Write([]byte(`{
				"device_code": "dev-code-1",
				"user_code": "BCDF-GHJK",
				"verification_uri": "` + "http://console.test/device" + `",
				"verification_uri_complete": "http://console.test/device?code=BCDF-GHJK",
				"expires_in": 900,
				"interval": 0
			}`))
		case "/api/auth/device/token":
			body, _ := io.ReadAll(r.Body)
			if !strings.Contains(string(body), "dev-code-1") {
				t.Errorf("poll body %q does not carry the device code", body)
			}
			polls++
			switch polls {
			case 1:
				w.WriteHeader(http.StatusBadRequest)
				_, _ = w.Write([]byte(`{"error":"authorization_pending"}`))
			case 2:
				w.WriteHeader(http.StatusBadRequest)
				_, _ = w.Write([]byte(`{"error":"slow_down"}`))
			default:
				w.WriteHeader(http.StatusCreated)
				_, _ = w.Write([]byte(`{"api_key":"` + key + `","key_id":"k1","prefix":"ftn_test"}`))
			}
		case "/api/auth/me":
			_, _ = w.Write([]byte(`{"id":"u1","email":"goat@example.com","role":"user"}`))
		default:
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	t.Setenv("FOUNTAIN_BASE_URL", srv.URL)
	t.Setenv("FOUNTAIN_PROFILE", "")

	credsPath := filepath.Join(t.TempDir(), "credentials")
	credentials.SetPathOverride(credsPath)
	t.Cleanup(func() { credentials.SetPathOverride("") })

	var sleeps []time.Duration
	deviceSleep = func(d time.Duration) { sleeps = append(sleeps, d) }
	t.Cleanup(func() { deviceSleep = time.Sleep })

	if err := authLoginDevice(); err != nil {
		t.Fatalf("authLoginDevice: %v", err)
	}
	if polls < 3 {
		t.Errorf("expected the loop to ride out pending and slow_down, got %d polls", polls)
	}
	// slow_down (poll 2) must have added five seconds to the pacing.
	if len(sleeps) < 2 || sleeps[1] != 5*time.Second {
		t.Errorf("slow_down did not back the interval off: sleeps = %v", sleeps)
	}

	content, err := os.ReadFile(credsPath)
	if err != nil {
		t.Fatalf("credentials file was not written: %v", err)
	}
	attrs := credentials.ParseAll(string(content))["default"]
	if attrs["api_key"] != key {
		t.Errorf("saved api_key = %q, want %q", attrs["api_key"], key)
	}
	if attrs["base_url"] != srv.URL {
		t.Errorf("saved base_url = %q, want %q", attrs["base_url"], srv.URL)
	}
}

// A denial must stop the loop with a clear error, not run out the clock.
func TestPollDeviceGrantStopsOnDenial(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"access_denied"}`))
	}))
	defer srv.Close()

	_, err := pollDeviceGrant(srv.URL, &deviceGrant{DeviceCode: "dev", ExpiresIn: 900, Interval: 0})
	if err == nil || !strings.Contains(err.Error(), "denied") {
		t.Fatalf("want a denial error, got %v", err)
	}
}

// stdinFrom replaces os.Stdin with a pipe holding `input` and returns the
// restore func. promptPassword falls back to a plain line read on a non-TTY,
// which is what a pipe is.
func stdinFrom(t *testing.T, input string) func() {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	if _, err := w.WriteString(input); err != nil {
		t.Fatalf("write to pipe: %v", err)
	}
	w.Close()
	orig := os.Stdin
	os.Stdin = r
	return func() {
		os.Stdin = orig
		r.Close()
	}
}
