package cmd

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/BinaryBourbon/fountain/cli/internal/acp"
	"github.com/BinaryBourbon/fountain/cli/internal/api"
	"github.com/BinaryBourbon/fountain/cli/internal/config"
	"github.com/BinaryBourbon/fountain/cli/internal/credentials"
	"github.com/spf13/cobra"
)

var acpLogLevel string

func init() {
	acpCmd := &cobra.Command{
		Use:   "acp",
		Short: "Speak the Agent Client Protocol on stdio (spawned by an editor)",
		Long: `Speak the Agent Client Protocol on stdio.

Not meant to be run by hand: an ACP-capable editor spawns this process and
talks JSON-RPC to it over the pipe. stdout carries the protocol and nothing
else; diagnostics go to stderr.

What it is, and is not: a control surface for a conversation running in a
Fountain sandbox — watch it, steer it, interrupt it. It has no access to the
files open in your editor, and the paths it reports are inside the sandbox,
not on your machine.`,
		RunE: func(cmd *cobra.Command, args []string) error { return runACP() },
	}
	acpCmd.Flags().StringVar(&acpLogLevel, "log-level", "info", "stderr log level: debug, info, warn, error")
	rootCmd.AddCommand(acpCmd)
}

func runACP() error {
	level, err := parseLogLevel(acpLogLevel)
	if err != nil {
		return err
	}

	// Every diagnostic goes to stderr. A single stray byte on stdout is an
	// unparseable line to the editor, which reports it as the agent crashing.
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))

	// SIGINT/SIGTERM and a closed stdin are the two ways an editor ends this
	// process, and both are ordinary. Neither is an error exit.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	opts := activeOpts()
	agent := acp.NewAgent(cliAuth{opts: opts}, log)

	log.Info("fountain acp starting",
		"base_url", config.BaseURL(opts),
		"profile", credentials.ProfileName(opts))

	return acp.NewConn(os.Stdin, os.Stdout, log).Serve(ctx, agent)
}

func parseLogLevel(s string) (slog.Level, error) {
	switch strings.ToLower(s) {
	case "debug":
		return slog.LevelDebug, nil
	case "info":
		return slog.LevelInfo, nil
	case "warn", "warning":
		return slog.LevelWarn, nil
	case "error":
		return slog.LevelError, nil
	default:
		return 0, fmt.Errorf("unknown log level %q (want debug, info, warn or error)", s)
	}
}

// cliAuth resolves credentials exactly the way every other subcommand does —
// FOUNTAIN_API_KEY, then the active profile in ~/.fountain/credentials. ADR
// 0015 declines ACP's remote transport partly to keep this in one place; a
// second credential path reachable only from an editor is the thing that
// decision exists to avoid.
type cliAuth struct {
	opts credentials.Opts
}

func (a cliAuth) Available() bool {
	_, err := config.APIKey(a.opts)
	return err == nil
}

// Verify ignores its context because api.Client builds its own (with a 60s
// timeout) per request. Threading one through is a change to every caller of
// that package, and belongs with the streaming work that actually needs
// cancellation (#704), not here.
func (a cliAuth) Verify(context.Context) error {
	var out authMe
	return api.New(a.opts).Get("/auth/me", &out)
}

// Describe names the instance and profile the credentials belong to. Pointing
// an editor at the wrong instance produces auth failures that look like a bad
// password, so the answer says which door was tried.
func (a cliAuth) Describe() string {
	return fmt.Sprintf("%s (profile %s)", config.BaseURL(a.opts), credentials.ProfileName(a.opts))
}
