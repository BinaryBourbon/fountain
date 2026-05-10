package cmd

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/BinaryBourbon/fountain/cli/internal/api"
	"github.com/BinaryBourbon/fountain/cli/internal/output"
	"github.com/BinaryBourbon/fountain/cli/internal/sse"
	"github.com/spf13/cobra"
)

func init() {
	convCmd := &cobra.Command{Use: "conv", Short: "Manage conversations"}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List conversations",
		RunE:  func(cmd *cobra.Command, args []string) error { return convList(cmd) },
	}
	listCmd.Flags().Bool("json", false, "output JSON")

	promptCmd := &cobra.Command{
		Use:   "prompt <id>",
		Short: "Send a prompt to a conversation and stream the result",
		Args:  cobra.ExactArgs(1),
		RunE:  func(cmd *cobra.Command, args []string) error { return convPrompt(cmd, args[0]) },
	}
	promptCmd.Flags().StringP("prompt", "p", "", "prompt text (required)")
	promptCmd.Flags().StringSliceP("image", "i", nil, "image file path (repeatable)")

	convCmd.AddCommand(
		listCmd,
		&cobra.Command{
			Use:   "show <id>",
			Short: "Show a conversation",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return convShow(args[0]) },
		},
		&cobra.Command{
			Use:   "stream <id>",
			Short: "Stream conversation events",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return convStream(args[0]) },
		},
		promptCmd,
		&cobra.Command{
			Use:   "interrupt <id>",
			Short: "Interrupt the running turn",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return convInterrupt(args[0]) },
		},
		&cobra.Command{
			Use:   "terminate <id>",
			Short: "Terminate a conversation",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return convTerminate(args[0]) },
		},
		&cobra.Command{
			Use:   "delete <id>",
			Short: "Delete a conversation",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return convDelete(args[0]) },
		},
	)
	rootCmd.AddCommand(convCmd)

	// `run` is a top-level shortcut: create + stream until done.
	runCmd := &cobra.Command{
		Use:   "run <agent-name-or-id>",
		Short: "Run an agent (create conversation + stream until done)",
		Args:  cobra.ExactArgs(1),
		RunE:  func(cmd *cobra.Command, args []string) error { return runAgent(cmd, args[0]) },
	}
	runCmd.Flags().StringP("prompt", "p", "", "prompt text (required)")
	runCmd.Flags().String("vault", "", "vault name or id")
	rootCmd.AddCommand(runCmd)
}

// ── list / show ────────────────────────────────────────────────────────

func convList(cmd *cobra.Command) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	c := activeClient()
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/conversations", &resp); err != nil {
		Fatal(err.Error())
	}
	if jsonOut {
		return output.PrintJSON(resp.Data)
	}
	rows := make([][]string, 0, len(resp.Data))
	for _, v := range resp.Data {
		rows = append(rows, []string{
			output.ToString(v["status"]),
			output.ShortID(output.ToString(v["id"])),
			output.ShortID(output.ToString(v["agent_id"])),
			output.ToString(v["runtime"]),
			output.ToString(v["inserted_at"]),
		})
	}
	output.Table([]string{"status", "id", "agent_id", "runtime", "started"}, rows)
	return nil
}

func convShow(id string) error {
	c := activeClient()
	var convResp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Get("/conversations/"+id, &convResp); err != nil {
		Fatal(err.Error())
	}
	var turnResp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/conversations/"+id+"/turns", &turnResp); err != nil {
		Fatal(err.Error())
	}

	conv := convResp.Data
	fmt.Printf("conversation %s\n", output.ToString(conv["id"]))
	fmt.Printf("  status:    %s\n", output.ToString(conv["status"]))
	fmt.Printf("  agent:     %s\n", output.ToString(conv["agent_id"]))
	fmt.Printf("  sandbox:   %s\n", output.ToString(conv["sandbox_id"]))
	fmt.Printf("  sprite:    %s\n", spriteLabel(conv["sandbox"]))
	fmt.Printf("  runtime:   %s\n", output.ToString(conv["runtime"]))
	fmt.Printf("  inserted:  %s\n", output.ToString(conv["inserted_at"]))
	fmt.Printf("\nturns (%d):\n", len(turnResp.Data))
	for _, t := range turnResp.Data {
		fmt.Printf("  #%s %s exit=%s  %s\n",
			output.ToString(t["turn_number"]),
			output.ToString(t["status"]),
			output.ToString(t["exit_code"]),
			output.Truncate(output.ToString(t["prompt"]), 80),
		)
	}
	return nil
}

func spriteLabel(v any) string {
	m, ok := v.(map[string]any)
	if !ok {
		return "—"
	}
	name, _ := m["sprite_name"].(string)
	status, _ := m["status"].(string)
	if name == "" {
		return "—"
	}
	return fmt.Sprintf("%s (%s)", name, status)
}

// ── streaming ──────────────────────────────────────────────────────────

func convStream(id string) error {
	return followUntilIdle(id)
}

func convPrompt(cmd *cobra.Command, id string) error {
	prompt, _ := cmd.Flags().GetString("prompt")
	if prompt == "" {
		Fatal("missing -p <prompt>")
	}
	imagePaths, _ := cmd.Flags().GetStringSlice("image")
	images := make([]map[string]string, 0, len(imagePaths))
	for _, p := range imagePaths {
		raw, err := os.ReadFile(p)
		if err != nil {
			Fatalf("read %s: %v", p, err)
		}
		images = append(images, map[string]string{
			"data":       base64.StdEncoding.EncodeToString(raw),
			"media_type": guessMediaType(p),
		})
	}
	c := activeClient()
	body := map[string]any{"prompt": prompt, "images": images}
	if err := c.Post("/conversations/"+id+"/prompts", body, nil); err != nil {
		Fatal(err.Error())
	}
	return followUntilIdle(id)
}

func guessMediaType(path string) string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	default:
		return "image/png"
	}
}

func convInterrupt(id string) error {
	c := activeClient()
	if err := c.Post("/conversations/"+id+"/interrupt", map[string]any{}, nil); err != nil {
		if api.StatusCode(err) == 409 {
			Fatal("no turn running")
		}
		Fatal(err.Error())
	}
	fmt.Printf("interrupted %s\n", id)
	return nil
}

func convTerminate(id string) error {
	c := activeClient()
	if err := c.Post("/conversations/"+id+"/terminate", map[string]any{}, nil); err != nil {
		Fatal(err.Error())
	}
	fmt.Printf("terminated %s\n", id)
	return nil
}

func convDelete(id string) error {
	c := activeClient()
	if err := c.Delete("/conversations/"+id, nil); err != nil {
		if api.StatusCode(err) == 404 {
			Fatal("not found")
		}
		Fatal(err.Error())
	}
	fmt.Printf("deleted %s\n", id)
	return nil
}

// ── run shortcut ────────────────────────────────────────────────────────

func runAgent(cmd *cobra.Command, target string) error {
	prompt, _ := cmd.Flags().GetString("prompt")
	if prompt == "" {
		Fatal("missing -p <prompt>")
	}
	vault, _ := cmd.Flags().GetString("vault")

	agentID := resolveAgentID(target)
	body := map[string]any{"agent_id": agentID, "prompt": prompt}
	if vault != "" {
		body["vault_id"] = resolveVaultID(vault)
	}

	c := activeClient()
	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Post("/conversations", body, &resp); err != nil {
		Fatal(err.Error())
	}
	convID := output.ToString(resp.Data["id"])
	fmt.Fprintf(os.Stderr, "▸ conversation %s\n", convID)
	return followUntilIdle(convID)
}

// ── stream loop ─────────────────────────────────────────────────────────

// followUntilIdle opens the SSE stream for conv `id` and prints output
// until a `stage=turn state=done` event arrives or the server closes.
func followUntilIdle(convID string) error {
	c := activeClient()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	req, err := c.NewStreamRequest(ctx, "/conversations/"+convID+"/stream", "")
	if err != nil {
		return err
	}
	httpClient := &http.Client{} // no global timeout — streams are long-lived
	resp, err := httpClient.Do(req)
	if err != nil {
		Fatalf("stream request failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		Fatalf("stream HTTP %d: %s", resp.StatusCode, body)
	}

	buf := make([]byte, 8192)
	var pending bytes.Buffer
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			pending.Write(buf[:n])
			events, leftover := sse.Feed(pending.String())
			pending.Reset()
			pending.WriteString(leftover)
			for _, ev := range events {
				if handleEvent(ev) {
					return nil
				}
			}
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			if ctx.Err() == context.DeadlineExceeded {
				Fatal("stream timeout")
			}
			Fatalf("stream read: %v", err)
		}
	}
}

// handleEvent prints output and returns true when the turn is done.
func handleEvent(ev sse.Event) bool {
	switch ev.Event {
	case "stage":
		data, ok := ev.Data.(map[string]any)
		if !ok {
			return false
		}
		stage, _ := data["stage"].(string)
		state, _ := data["state"].(string)
		if stage == "turn" && state == "done" {
			exit := exitCodeFromStageDone(data)
			fmt.Fprintf(os.Stderr, "▸ turn done (exit_code=%s)\n", exit)
			return true
		}
		fmt.Fprintf(os.Stderr, "▸ %s: %s\n", stage, state)
	case "output":
		data, ok := ev.Data.(map[string]any)
		if !ok {
			return false
		}
		text := formatOutput(data)
		if text != "" {
			fmt.Print(text)
		}
	}
	return false
}

// exitCodeFromStageDone digs `data.data.exit_code` out of a turn-done event.
// The Elixir code looked up the same path; the inner `data` was JSON-encoded,
// so we accept either a nested map or a JSON string.
func exitCodeFromStageDone(data map[string]any) string {
	inner := data["data"]
	if s, ok := inner.(string); ok {
		var m map[string]any
		if json.Unmarshal([]byte(s), &m) == nil {
			return output.ToString(m["exit_code"])
		}
	}
	if m, ok := inner.(map[string]any); ok {
		return output.ToString(m["exit_code"])
	}
	return ""
}

func formatOutput(data map[string]any) string {
	stream, _ := data["stream"].(string)
	raw, _ := data["data"].(string)
	if stream == "stderr" {
		return "\x1b[31m" + raw + "\x1b[0m"
	}
	if raw == "" {
		return ""
	}
	var b strings.Builder
	for _, line := range strings.Split(raw, "\n") {
		if line == "" {
			continue
		}
		b.WriteString(formatStreamJSONLine(line))
	}
	return b.String()
}

// formatStreamJSONLine renders a single line from the assistant/user/result
// JSON Lines stream. Mirrors conv.ex's format_stream_json_line/1.
func formatStreamJSONLine(line string) string {
	var msg map[string]any
	if json.Unmarshal([]byte(line), &msg) != nil {
		return ""
	}
	t, _ := msg["type"].(string)
	switch t {
	case "assistant":
		message, _ := msg["message"].(map[string]any)
		content, _ := message["content"].([]any)
		var b strings.Builder
		for _, item := range content {
			c, ok := item.(map[string]any)
			if !ok {
				continue
			}
			ct, _ := c["type"].(string)
			switch ct {
			case "text":
				if text, ok := c["text"].(string); ok {
					b.WriteString(text)
				}
			case "tool_use":
				name, _ := c["name"].(string)
				input := c["input"]
				inputJSON, _ := json.Marshal(input)
				b.WriteString("\n\x1b[36m[")
				b.WriteString(name)
				b.WriteString("]\x1b[0m ")
				b.Write(inputJSON)
				b.WriteString("\n")
			}
		}
		return b.String()

	case "user":
		message, _ := msg["message"].(map[string]any)
		contentArr, _ := message["content"].([]any)
		if len(contentArr) > 0 {
			c, ok := contentArr[0].(map[string]any)
			if ok {
				if text, ok := c["content"].(string); ok {
					return "\n\x1b[2m→ " + output.Truncate(text, 200) + "\x1b[0m\n"
				}
			}
		}
	case "result":
		if r, ok := msg["result"].(string); ok {
			return "\n\x1b[32m✓ " + r + "\x1b[0m\n"
		}
	}
	return ""
}
