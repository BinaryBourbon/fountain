package manifest

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRead_SingleFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "spec.yml")
	yaml := `apiVersion: aod/v1
kind: Environment
metadata:
  name: prod
spec:
  setup_script: "echo hi"
  secrets:
    GH: ${GH_PAT}
`
	if err := os.WriteFile(path, []byte(yaml), 0o600); err != nil {
		t.Fatal(err)
	}
	docs, err := Read(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(docs) != 1 {
		t.Fatalf("docs: %d", len(docs))
	}
	d := docs[0]
	if d.Kind != "Environment" || d.Name() != "prod" {
		t.Fatalf("kind=%q name=%q", d.Kind, d.Name())
	}
	if d.Spec["setup_script"] != "echo hi" {
		t.Fatalf("spec: %v", d.Spec)
	}
	secrets := d.Spec["secrets"].(map[string]any)
	if secrets["GH"] != "${GH_PAT}" {
		t.Fatalf("secrets: %v", secrets)
	}
}

func TestRead_MultiDoc(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "all.yaml")
	yaml := `---
apiVersion: aod/v1
kind: Environment
metadata:
  name: a
spec: {}
---
apiVersion: aod/v1
kind: Vault
metadata:
  name: b
spec: {}
`
	_ = os.WriteFile(path, []byte(yaml), 0o600)
	docs, err := Read(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(docs) != 2 {
		t.Fatalf("docs: %d", len(docs))
	}
}

func TestRead_DirectoryFiltersNonResource(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "a.yml"), []byte(`apiVersion: aod/v1
kind: Vault
metadata:
  name: a
spec: {}
`), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "ci.yml"), []byte(`name: build
on: push
`), 0o600)
	docs, err := Read(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(docs) != 1 || docs[0].Name() != "a" {
		t.Fatalf("docs: %v", docs)
	}
}
