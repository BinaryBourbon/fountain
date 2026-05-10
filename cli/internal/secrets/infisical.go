package secrets

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// Infisical wraps the `infisical` CLI for
// infisical://<project?>/<env>/<path?>/<name> refs.
type Infisical struct{}

func (*Infisical) Prefix() string { return "infisical://" }

var errInfisicalNotInstalled = errors.New("infisical_not_installed")

type infisicalInvalidRef struct{ Reason string }

func (e *infisicalInvalidRef) Error() string { return "invalid_ref: " + e.Reason }

type infisicalFailed struct{ Output string }

func (e *infisicalFailed) Error() string { return "infisical_failed: " + e.Output }

type infisicalParts struct {
	Project string // empty → fall through to .infisical.json / INFISICAL_PROJECT_ID
	Env     string
	Path    string
	Name    string
}

func (*Infisical) Read(ref string) (string, error) {
	if !strings.HasPrefix(ref, "infisical://") {
		return "", &infisicalInvalidRef{Reason: "missing infisical:// prefix"}
	}
	rest := strings.TrimPrefix(ref, "infisical://")
	parts, err := parseInfisical(rest)
	if err != nil {
		return "", err
	}
	if _, err := exec.LookPath("infisical"); err != nil {
		return "", errInfisicalNotInstalled
	}
	args := []string{"secrets", "get", parts.Name, "--env=" + parts.Env, "--path=" + parts.Path, "--plain"}
	if parts.Project != "" {
		args = append(args, "--projectId="+parts.Project)
	}
	out, err := combinedOutput("infisical", args...)
	if err != nil {
		return "", &infisicalFailed{Output: strings.TrimSpace(out)}
	}
	return strings.TrimRight(out, "\n"), nil
}

// parseInfisical splits the URI tail into its positional segments.
//
//	<project>/<env>/<name>                    → path = "/"
//	<project>/<env>/<seg>/<seg>/.../<name>    → path = "/" + joined middle segments
//
// The project segment may be empty (the CLI then falls through to its own
// project resolution).
func parseInfisical(rest string) (infisicalParts, error) {
	segments := strings.Split(rest, "/")
	switch {
	case len(segments) == 3 && segments[1] != "" && segments[2] != "":
		return infisicalParts{
			Project: segments[0],
			Env:     segments[1],
			Path:    "/",
			Name:    segments[2],
		}, nil
	case len(segments) >= 4 && segments[1] != "":
		name := segments[len(segments)-1]
		mid := segments[2 : len(segments)-1]
		if name == "" {
			return infisicalParts{}, &infisicalInvalidRef{Reason: "missing secret name (last segment)"}
		}
		for _, s := range mid {
			if s == "" {
				return infisicalParts{}, &infisicalInvalidRef{Reason: "empty path segment"}
			}
		}
		return infisicalParts{
			Project: segments[0],
			Env:     segments[1],
			Path:    "/" + strings.Join(mid, "/"),
			Name:    name,
		}, nil
	}
	return infisicalParts{}, &infisicalInvalidRef{
		Reason: "expected infisical://<project?>/<env>/<path?>/<name> with at least env and name",
	}
}

func (*Infisical) FormatError(err error) string {
	if errors.Is(err, errInfisicalNotInstalled) {
		return "Infisical CLI (`infisical`) not on PATH — install from https://infisical.com/docs/cli/overview"
	}
	var ir *infisicalInvalidRef
	if errors.As(err, &ir) {
		return "invalid infisical:// reference: " + ir.Reason
	}
	var f *infisicalFailed
	if errors.As(err, &f) {
		if f.Output == "" {
			return "infisical exited non-zero with no output"
		}
		return f.Output
	}
	return fmt.Sprintf("%v", err)
}
