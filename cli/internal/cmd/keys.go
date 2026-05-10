package cmd

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"github.com/BinaryBourbon/fountain/cli/internal/api"
	"github.com/BinaryBourbon/fountain/cli/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	keysCmd := &cobra.Command{Use: "keys", Short: "Manage Fountain API keys"}
	keysCmd.AddCommand(
		&cobra.Command{
			Use:   "list",
			Short: "List API keys",
			RunE:  func(cmd *cobra.Command, args []string) error { return keysList() },
		},
		&cobra.Command{
			Use:   "create <name>",
			Short: "Create a new API key",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return keysCreate(args[0]) },
		},
		&cobra.Command{
			Use:   "revoke <id>",
			Short: "Revoke an API key",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return keysRevoke(args[0]) },
		},
	)
	rootCmd.AddCommand(keysCmd)
}

func keysList() error {
	c := activeClient()
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/auth/api-keys", &resp); err != nil {
		Fatal(err.Error())
	}
	rows := make([][]string, 0, len(resp.Data))
	for _, k := range resp.Data {
		lastUsed := output.ToString(k["last_used_at"])
		if lastUsed == "" {
			lastUsed = "never"
		}
		rows = append(rows, []string{
			output.ToString(k["key_prefix"]),
			output.ToString(k["name"]),
			lastUsed,
		})
	}
	output.Table([]string{"prefix", "name", "last_used"}, rows)
	return nil
}

func keysCreate(name string) error {
	c := activeClient()
	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Post("/auth/api-keys", map[string]string{"name": name}, &resp); err != nil {
		Fatal(err.Error())
	}
	key := output.ToString(resp.Data["key"])
	if key == "" {
		Fatalf("unexpected response: %v", resp.Data)
	}
	fmt.Println()
	fmt.Println("╭────────────────────────────────────────────────────────────────╮")
	fmt.Println("│  Save this key — it will not be shown again.                  │")
	fmt.Println("╰────────────────────────────────────────────────────────────────╯")
	fmt.Println()
	fmt.Println(key)
	fmt.Println()
	fmt.Printf("Name:   %s\n", output.ToString(resp.Data["name"]))
	fmt.Printf("Prefix: %s\n", output.ToString(resp.Data["key_prefix"]))
	fmt.Println()
	return nil
}

func keysRevoke(id string) error {
	fmt.Printf("Revoke API key %s? This cannot be undone. [y/N] ", id)
	r := bufio.NewReader(os.Stdin)
	answer, _ := r.ReadString('\n')
	answer = strings.ToLower(strings.TrimSpace(answer))
	if answer != "y" && answer != "yes" {
		fmt.Println("Aborted.")
		return nil
	}
	c := activeClient()
	if err := c.Delete("/auth/api-keys/"+id, nil); err != nil {
		if api.StatusCode(err) == 404 {
			Fatalf("key not found: %s", id)
		}
		Fatal(err.Error())
	}
	fmt.Printf("Revoked %s.\n", id)
	return nil
}
