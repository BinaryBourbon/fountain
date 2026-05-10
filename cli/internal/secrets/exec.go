package secrets

import "os/exec"

// combinedOutput runs cmd with args and returns combined stdout+stderr.
// On non-zero exit the output is still returned alongside the error.
func combinedOutput(cmd string, args ...string) (string, error) {
	out, err := exec.Command(cmd, args...).CombinedOutput()
	return string(out), err
}
