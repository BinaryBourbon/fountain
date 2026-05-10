// Package secrets resolves external secret references at apply time.
//
// Each Resolver is bound to a URI prefix (op://, bws://, infisical://).
// Apply walks `spec.secrets` values, finds the resolver whose prefix
// matches, and replaces the value with whatever the resolver returns.
package secrets

import "strings"

// Resolver is the contract for an external secret backend.
type Resolver interface {
	// Prefix is the URI scheme this resolver claims, e.g. "op://".
	Prefix() string
	// Read returns the plaintext for ref, or an error.
	Read(ref string) (string, error)
	// FormatError converts a Read error into a human-readable message
	// for the apply CLI's failure dump.
	FormatError(err error) string
}

// Default is the registry used by Apply when no override is supplied.
var Default = []Resolver{
	&OnePassword{},
	&Bitwarden{},
	&Infisical{},
}

// ForValue returns the first Resolver in `list` whose prefix matches s.
// Returns nil for non-string values or when no scheme matches.
func ForValue(s string, list []Resolver) Resolver {
	for _, r := range list {
		if strings.HasPrefix(s, r.Prefix()) {
			return r
		}
	}
	return nil
}
