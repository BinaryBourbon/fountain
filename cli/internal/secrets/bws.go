package secrets

import (
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// Bitwarden wraps the `bws` (Bitwarden Secrets Manager) CLI for
// bws://<secret-uuid> refs.
type Bitwarden struct{}

func (*Bitwarden) Prefix() string { return "bws://" }

var (
	errBwsNotInstalled = errors.New("bws_not_installed")
	errBwsEmptyRef     = errors.New("bws_empty_ref")
	errBwsInvalidRef   = errors.New("bws_invalid_ref")
)

type bwsFailed struct{ Output string }

func (e *bwsFailed) Error() string { return "bws_failed: " + e.Output }

type bwsUnexpected struct{ Reason string }

func (e *bwsUnexpected) Error() string { return "bws_unexpected_output: " + e.Reason }

func (*Bitwarden) Read(ref string) (string, error) {
	if !strings.HasPrefix(ref, "bws://") {
		return "", errBwsInvalidRef
	}
	uuid := strings.TrimPrefix(ref, "bws://")
	if uuid == "" {
		return "", errBwsEmptyRef
	}
	if _, err := exec.LookPath("bws"); err != nil {
		return "", errBwsNotInstalled
	}
	out, err := combinedOutput("bws", "secret", "get", uuid)
	if err != nil {
		return "", &bwsFailed{Output: strings.TrimSpace(out)}
	}
	var parsed struct {
		Value *string `json:"value"`
	}
	if err := json.Unmarshal([]byte(out), &parsed); err != nil {
		return "", &bwsUnexpected{Reason: "could not parse `bws` output as JSON"}
	}
	if parsed.Value == nil {
		return "", &bwsUnexpected{Reason: "JSON had no string `value` field"}
	}
	return *parsed.Value, nil
}

func (*Bitwarden) FormatError(err error) string {
	switch {
	case errors.Is(err, errBwsNotInstalled):
		return "Bitwarden Secrets Manager CLI (`bws`) not on PATH — install from https://bitwarden.com/help/secrets-manager-cli/"
	case errors.Is(err, errBwsEmptyRef):
		return "bws://<uuid> reference is missing the UUID"
	case errors.Is(err, errBwsInvalidRef):
		return "invalid bws:// reference"
	}
	var f *bwsFailed
	if errors.As(err, &f) {
		if f.Output == "" {
			return "bws exited non-zero with no output"
		}
		return f.Output
	}
	var u *bwsUnexpected
	if errors.As(err, &u) {
		return "unexpected bws output: " + u.Reason
	}
	return fmt.Sprintf("%v", err)
}
