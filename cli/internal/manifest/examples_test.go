package manifest

import (
	"os"
	"path/filepath"
	"testing"
)

// TestExamplesParse walks the repo's examples/ tree and asserts every YAML
// document in it is a well-formed resource: a known kind, a metadata.name,
// and a map spec. Read() silently drops docs missing apiVersion/kind, which
// is right for a user's mixed specs tree and wrong for our own examples —
// so this walks the files directly and checks every document.
func TestExamplesParse(t *testing.T) {
	root := filepath.Join("..", "..", "..", "examples")
	if _, err := os.Stat(root); err != nil {
		t.Fatalf("examples/ not found relative to cli/internal/manifest: %v", err)
	}

	files, err := listYAMLFiles(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) == 0 {
		t.Fatal("no .yml/.yaml files under examples/")
	}

	knownKinds := map[string]bool{"Environment": true, "Vault": true, "Agent": true}
	total := 0
	for _, f := range files {
		docs, err := readFile(f)
		if err != nil {
			t.Errorf("%s: %v", f, err)
			continue
		}
		if len(docs) == 0 {
			t.Errorf("%s: no documents", f)
		}
		for i, d := range docs {
			total++
			if !d.IsResource() {
				t.Errorf("%s doc %d: missing apiVersion or kind (would be silently skipped by apply)", f, i)
				continue
			}
			if !knownKinds[d.Kind] {
				t.Errorf("%s doc %d: unknown kind %q", f, i, d.Kind)
			}
			if d.Name() == "" {
				t.Errorf("%s doc %d (%s): missing metadata.name", f, i, d.Kind)
			}
			if d.Spec == nil {
				t.Errorf("%s doc %d (%s/%s): missing map spec", f, i, d.Kind, d.Name())
			}
			// Secrets, when present, must be the map form: the server keeps a
			// map and silently drops anything else, and the CLI's ${VAR} and
			// secret-manager resolution only walk the map form.
			if raw, ok := d.Spec["secrets"]; ok {
				if _, isMap := raw.(map[string]any); !isMap {
					t.Errorf("%s doc %d (%s/%s): spec.secrets must be a map of KEY: value", f, i, d.Kind, d.Name())
				}
			}
		}
	}
	if total == 0 {
		t.Fatal("no resource documents under examples/")
	}
}
