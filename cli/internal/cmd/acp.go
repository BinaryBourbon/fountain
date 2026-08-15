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
	"github.com/BinaryBourbon/fountain/cli/internal/output"
	"github.com/spf13/cobra"
)

var (
	acpLogLevel string
	acpAgent    string
)

func init() {
	acpCmd := &cobra.Command{
		Use:   "acp",
		Short: "Speak the Agent Client Protocol on stdio (spawned by an editor)",
		Long: `Speak the Agent Client Protocol on stdio.

Not meant to be run by hand: an ACP-capable editor spawns this process and
talks JSON-RPC to it over the pipe. stdout carries the protocol and nothing
else; diagnostics go to stderr.

--agent names the Fountain agent a session runs — the protocol has no field
for it, so it is configured here. Point one editor entry at each agent you
want to reach.

What it is, and is not: a control surface for a conversation running in a
Fountain sandbox — watch it, steer it, interrupt it. It has no access to the
files open in your editor, and the paths it reports are inside the sandbox,
not on your machine.`,
		RunE: func(cmd *cobra.Command, args []string) error { return runACP() },
	}
	acpCmd.Flags().StringVar(&acpAgent, "agent", "", "Fountain agent name or id to open sessions against")
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
	agent := acp.NewAgent(cliAuth{opts: opts}, fountainAPI{opts: opts}, acpAgent, log)

	// An unset --agent is not fatal here: the editor still gets a working
	// handshake, and the refusal arrives at `session/new` where the editor can
	// show it. Exiting at startup instead produces a process that dies before
	// it can say why, which most clients report as "the agent crashed".
	log.Info("fountain acp starting",
		"base_url", config.BaseURL(opts),
		"profile", credentials.ProfileName(opts),
		"agent", acpAgent)

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

// fountainAPI is the adapter's view of the HTTP API. Every other subcommand
// reaches the API through Fatal-on-error helpers, which would be exactly wrong
// here: a failure inside a session method is a JSON-RPC error the editor
// renders, not a reason to kill a process the editor is talking to.
type fountainAPI struct {
	opts credentials.Opts
}

func (f fountainAPI) Agent(_ context.Context, target string) (acp.AgentRef, error) {
	c := api.New(f.opts)

	if isUUID(target) {
		var resp struct {
			Data map[string]any `json:"data"`
		}
		if err := c.Get("/agents/"+target, &resp); err != nil {
			return acp.AgentRef{}, err
		}
		return agentRef(resp.Data), nil
	}

	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/agents", &resp); err != nil {
		return acp.AgentRef{}, err
	}
	for _, a := range resp.Data {
		if output.ToString(a["name"]) == target {
			return agentRef(a), nil
		}
	}
	return acp.AgentRef{}, fmt.Errorf("no agent named %q", target)
}

// agentRef reads the capability from the server rather than deciding it here.
// A runtime list compiled into this binary would be wrong from the moment a
// held-back runtime is converted until the next CLI release.
func agentRef(data map[string]any) acp.AgentRef {
	acpOK, _ := data["acp"].(bool)
	return acp.AgentRef{
		ID:      output.ToString(data["id"]),
		Name:    output.ToString(data["name"]),
		Runtime: output.ToString(data["runtime"]),
		ACP:     acpOK,
	}
}

func (f fountainAPI) CreateConversation(_ context.Context, agentID string) (string, error) {
	var resp struct {
		Data map[string]any `json:"data"`
	}
	// No prompt: the conversation is created empty and the editor's first
	// `session/prompt` becomes turn 1. Provisioning starts server-side either
	// way, so the sandbox is warming while the developer types.
	if err := api.New(f.opts).Post("/conversations", map[string]any{"agent_id": agentID}, &resp); err != nil {
		return "", err
	}
	id := output.ToString(resp.Data["id"])
	if id == "" {
		return "", fmt.Errorf("conversation created but the response carried no id")
	}
	return id, nil
}
