// Package substitution implements ${VAR} expansion for manifest secrets.
//
//	${VAR}    eager — substituted from the supplied vars map
//	$${VAR}   escape — written through as literal `${VAR}`
//	$$        literal `$`
//
// Identifiers must match [A-Z_][A-Z0-9_]* (UPPER_SNAKE_CASE).
//
// Walks recursively through maps and lists; only string leaves are
// rewritten. Missing keys are accumulated across the entire input so
// the caller can surface every typo at once.
package substitution

import (
	"fmt"
	"regexp"
	"sort"
)

var refRE = regexp.MustCompile(`\$\$|\$\{([A-Z_][A-Z0-9_]*)\}`)

// MissingVarsError lists variable names that were referenced but not provided.
type MissingVarsError struct{ Missing []string }

func (e *MissingVarsError) Error() string {
	return fmt.Sprintf("missing vars: %v", e.Missing)
}

// Apply walks value recursively and substitutes ${VAR} references.
// Returns a fresh value tree on success; on missing vars, returns the
// input unchanged plus a MissingVarsError listing every missing key.
func Apply(value any, vars map[string]string) (any, error) {
	missing := map[string]struct{}{}
	result := walk(value, vars, missing)
	if len(missing) == 0 {
		return result, nil
	}
	list := make([]string, 0, len(missing))
	for k := range missing {
		list = append(list, k)
	}
	sort.Strings(list)
	return value, &MissingVarsError{Missing: list}
}

func walk(value any, vars map[string]string, missing map[string]struct{}) any {
	switch v := value.(type) {
	case string:
		// Find missing first so we know whether to substitute.
		need := requiredVars(v)
		complete := true
		for _, name := range need {
			if _, ok := vars[name]; !ok {
				missing[name] = struct{}{}
				complete = false
			}
		}
		if !complete {
			return v
		}
		return substitute(v, vars)

	case map[string]any:
		out := make(map[string]any, len(v))
		for k, child := range v {
			out[k] = walk(child, vars, missing)
		}
		return out

	case map[string]string:
		out := make(map[string]string, len(v))
		for k, child := range v {
			r := walk(child, vars, missing)
			if s, ok := r.(string); ok {
				out[k] = s
			} else {
				out[k] = fmt.Sprintf("%v", r)
			}
		}
		return out

	case []any:
		out := make([]any, len(v))
		for i, child := range v {
			out[i] = walk(child, vars, missing)
		}
		return out

	default:
		return v
	}
}

func requiredVars(s string) []string {
	var out []string
	for _, m := range refRE.FindAllStringSubmatch(s, -1) {
		if m[0] == "$$" {
			continue
		}
		out = append(out, m[1])
	}
	return out
}

func substitute(s string, vars map[string]string) string {
	return refRE.ReplaceAllStringFunc(s, func(match string) string {
		if match == "$$" {
			return "$"
		}
		// match is ${NAME}
		name := match[2 : len(match)-1]
		return vars[name]
	})
}
