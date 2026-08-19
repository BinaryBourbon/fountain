package cmd

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"

	"github.com/BinaryBourbon/fountain/cli/internal/config"
	"github.com/BinaryBourbon/fountain/cli/internal/runner"
	"github.com/spf13/cobra"
)

var (
	runnerName     string
	runnerRoot     string
	runnerLogLevel string
)

func init() {
	runnerCmd := &cobra.Command{
		Use:   "runner",
		Short: "Turn this machine into a sandbox provider for your Fountain agents",
		Long: `Run this machine as a self-hosted Fountain runner.

The daemon dials out to Fountain (no inbound port, works behind NAT), holds
the connection, and serves sandboxes for agents whose sandbox_provider is
"runner": each sandbox is a directory under --root, and the agent's processes
run here, as you, with HOME pointed at that directory. Idle sandboxes park by
stopping their processes; the directory — the agent's memory — stays.

Trusted mode, and the only mode: there is no VM, container or egress policy
between the agent and this machine. Run it on a machine you would hand a
capable colleague a shell on. See docs/integrations/runners.md.

Names are unique per account; a second daemon with the same name is refused.
The default name is this machine's hostname.`,
		RunE: func(cmd *cobra.Command, args []string) error { return runRunner() },
	}
	runnerCmd.Flags().StringVar(&runnerName, "name", "", "runner name (default: the hostname, lowercased)")
	runnerCmd.Flags().StringVar(&runnerRoot, "root", "", "sandbox root (default: ~/.fountain/runners/<name>/sandboxes)")
	runnerCmd.Flags().StringVar(&runnerLogLevel, "log-level", "info", "debug|info|warn|error")
	rootCmd.AddCommand(runnerCmd)
}

var runnerNameClean = regexp.MustCompile(`[^a-z0-9._-]+`)

// DefaultRunnerName derives a valid runner name from a hostname.
func DefaultRunnerName(hostname string) string {
	name := strings.ToLower(hostname)
	if i := strings.IndexByte(name, '.'); i > 0 {
		name = name[:i]
	}
	name = runnerNameClean.ReplaceAllString(name, "-")
	name = strings.Trim(name, "-._")
	if name == "" {
		name = "runner"
	}
	if len(name) > 63 {
		name = name[:63]
	}
	return name
}

func runRunner() error {
	var level slog.Level
	if err := level.UnmarshalText([]byte(runnerLogLevel)); err != nil {
		return fmt.Errorf("--log-level: %w", err)
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))

	opts := activeOpts()
	token, err := config.APIKey(opts)
	if err != nil {
		return err
	}
	name := runnerName
	if name == "" {
		host, _ := os.Hostname()
		name = DefaultRunnerName(host)
	}
	root := runnerRoot
	if root == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return fmt.Errorf("resolve home directory: %w", err)
		}
		root = filepath.Join(home, ".fountain", "runners", name, "sandboxes")
	}
	root, err = filepath.Abs(root)
	if err != nil {
		return err
	}

	d, err := runner.New(root, log)
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	fmt.Fprintf(os.Stderr, "fountain runner %q: sandboxes in %s, connecting to %s\n", name, root, config.BaseURL(opts))
	err = runner.Run(ctx, runner.Config{
		BaseURL: config.BaseURL(opts),
		Token:   token,
		Name:    name,
		Root:    root,
		Version: Version,
	}, d, log)
	// Sessions belong to this process; when it goes, they go — say so rather
	// than leaving orphans writing into a closed pipe.
	d.StopAll()
	return err
}
