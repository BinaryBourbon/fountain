package cmd

import (
	"fmt"
	"strings"

	"github.com/BinaryBourbon/fountain/cli/internal/api"
	"github.com/BinaryBourbon/fountain/cli/internal/output"
	"github.com/spf13/cobra"
)

// buzzRespondToModes are buzz-acp's --respond-to modes, as the server's
// BuzzIdentity.respond_to_modes/0 accepts them.
var buzzRespondToModes = []string{"owner-only", "allowlist", "anyone", "nobody"}

func init() {
	buzzCmd := &cobra.Command{
		Use:   "buzz",
		Short: "Hosted Buzz agents (docs/integrations/buzz.md)",
	}
	agentsCmd := &cobra.Command{
		Use:   "agents",
		Short: "Manage hosted Buzz agents",
	}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List hosted Buzz agents",
		RunE:  func(cmd *cobra.Command, args []string) error { return buzzAgentsList(cmd) },
	}
	listCmd.Flags().Bool("json", false, "output JSON")

	// The operator's knob for who may @-mention a hosted agent (#790). The
	// desktop cannot resend its respond_to for a provider agent it has already
	// deployed, so this is how the policy changes after the fact.
	setAccessCmd := &cobra.Command{
		Use:   "set-access <name-or-id>",
		Short: "Change who may @-mention a hosted Buzz agent (restarts its harness)",
		Long: `Set buzz-acp's inbound author gate on a hosted Buzz agent and restart its
harness so it takes effect.

  --respond-to  owner-only | allowlist | anyone | nobody
  --allowlist   comma-separated 64-hex pubkeys (allowlist mode; required non-empty there)

Note: a later provider deploy from the Buzz desktop resends the desktop's own
record for the agent and overwrites what is set here.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error { return buzzAgentsSetAccess(cmd, args[0]) },
	}
	setAccessCmd.Flags().String("respond-to", "", "owner-only | allowlist | anyone | nobody")
	setAccessCmd.Flags().String("allowlist", "", "comma-separated 64-hex pubkeys admitted in allowlist mode")

	agentsCmd.AddCommand(listCmd, setAccessCmd)
	buzzCmd.AddCommand(agentsCmd)
	rootCmd.AddCommand(buzzCmd)
}

func buzzAgentsList(cmd *cobra.Command) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	c := activeClient()
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/buzz/agents", &resp); err != nil {
		Fatal(err.Error())
	}
	if jsonOut {
		return output.PrintJSON(resp.Data)
	}
	rows := make([][]string, 0, len(resp.Data))
	for _, a := range resp.Data {
		rows = append(rows, []string{
			output.ToString(a["name"]),
			output.ShortID(output.ToString(a["id"])),
			buzzAccessLabel(a),
			output.Truncate(output.ToString(a["pubkey"]), 16),
			output.ToString(a["enabled"]),
		})
	}
	output.Table([]string{"name", "id", "respond_to", "pubkey", "enabled"}, rows)
	return nil
}

// buzzAccessLabel renders the gate the way an operator thinks about it:
// "allowlist(2)" rather than a bare mode next to a separate column.
func buzzAccessLabel(a map[string]any) string {
	mode := output.ToString(a["respond_to"])
	if mode != "allowlist" {
		return mode
	}
	n := 0
	if list, ok := a["respond_to_allowlist"].([]any); ok {
		n = len(list)
	}
	return fmt.Sprintf("allowlist(%d)", n)
}

// buzzAccessBody validates the flags client-side so a typo is a usage error
// here rather than a 422 there, and builds the PATCH body. Only flags that
// were set are sent: mode alone keeps the server's allowlist.
func buzzAccessBody(respondTo, allowlist string, allowlistSet bool) (map[string]any, error) {
	body := map[string]any{}
	if respondTo != "" {
		ok := false
		for _, m := range buzzRespondToModes {
			if m == respondTo {
				ok = true
				break
			}
		}
		if !ok {
			return nil, fmt.Errorf("--respond-to must be one of %s", strings.Join(buzzRespondToModes, ", "))
		}
		body["respond_to"] = respondTo
	}
	if allowlistSet {
		var pks []string
		for _, pk := range strings.Split(allowlist, ",") {
			if pk = strings.TrimSpace(pk); pk != "" {
				pks = append(pks, pk)
			}
		}
		if pks == nil {
			pks = []string{}
		}
		body["respond_to_allowlist"] = pks
	}
	if len(body) == 0 {
		return nil, fmt.Errorf("nothing to change: pass --respond-to and/or --allowlist")
	}
	return body, nil
}

func buzzAgentsSetAccess(cmd *cobra.Command, target string) error {
	respondTo, _ := cmd.Flags().GetString("respond-to")
	allowlist, _ := cmd.Flags().GetString("allowlist")
	body, err := buzzAccessBody(respondTo, allowlist, cmd.Flags().Changed("allowlist"))
	if err != nil {
		Fatal(err.Error())
	}
	c := activeClient()
	id := resolveBuzzAgentID(target)
	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Patch("/buzz/agents/"+id, body, &resp); err != nil {
		if api.StatusCode(err) == 404 {
			Fatal("not found")
		}
		Fatal(err.Error())
	}
	fmt.Printf("buzz agent  ~  %s  respond_to=%s\n", output.ToString(resp.Data["name"]), buzzAccessLabel(resp.Data))
	return nil
}

func resolveBuzzAgentID(target string) string {
	if isUUID(target) {
		return target
	}
	c := activeClient()
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/buzz/agents", &resp); err != nil {
		Fatal(err.Error())
	}
	for _, a := range resp.Data {
		if output.ToString(a["name"]) == target || output.ToString(a["display_name"]) == target {
			return output.ToString(a["id"])
		}
	}
	Fatalf("no hosted Buzz agent named %q", target)
	return ""
}
