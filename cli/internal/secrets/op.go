package secrets

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// OnePassword wraps the `op` CLI for op://<vault>/<item>/<field> refs.
type OnePassword struct{}

func (*OnePassword) Prefix() string { return "op://" }

// Sentinel errors so FormatError can produce the right message.
var (
	errOpNotInstalled = errors.New("op_not_installed")
)

type opFailed struct{ Output string }

func (e *opFailed) Error() string { return "op_failed: " + e.Output }

func (*OnePassword) Read(ref string) (string, error) {
	if _, err := exec.LookPath("op"); err != nil {
		return "", errOpNotInstalled
	}
	out, err := combinedOutput("op", "read", "--no-newline", ref)
	if err != nil {
		return "", &opFailed{Output: strings.TrimSpace(out)}
	}
	return out, nil
}

func (*OnePassword) FormatError(err error) string {
	if errors.Is(err, errOpNotInstalled) {
		return "1Password CLI (`op`) not on PATH — install from https://developer.1password.com/docs/cli/get-started"
	}
	var f *opFailed
	if errors.As(err, &f) {
		if f.Output == "" {
			return "op exited non-zero with no output"
		}
		return f.Output
	}
	return fmt.Sprintf("%v", err)
}
