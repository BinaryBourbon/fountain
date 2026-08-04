package secrets

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeCLI installs an executable shell script named cmd on a PATH containing
// only the returned temp dir, so Read's LookPath and combinedOutput hit the
// fake instead of any real secret-manager CLI. The script appends its
// arguments to <dir>/<cmd>.args for command-construction assertions.
func fakeCLI(t *testing.T, cmd, script string) string {
	t.Helper()
	dir := t.TempDir()
	body := "#!/bin/sh\necho \"$@\" >> \"" + filepath.Join(dir, cmd+".args") + "\"\n" + script + "\n"
	if err := os.WriteFile(filepath.Join(dir, cmd), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	return dir
}

// noCLI empties PATH so LookPath fails for every command.
func noCLI(t *testing.T) {
	t.Helper()
	t.Setenv("PATH", t.TempDir())
}

func recordedArgs(t *testing.T, dir, cmd string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, cmd+".args"))
	if err != nil {
		t.Fatalf("fake %s was never invoked: %v", cmd, err)
	}
	return strings.TrimSpace(string(b))
}
