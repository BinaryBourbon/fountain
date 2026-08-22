package cmd

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"github.com/BinaryBourbon/fountain/cli/internal/output"
	"github.com/spf13/cobra"
)

// webhookEndpoint mirrors FountainWeb.WebhookEndpointJSON.summary/1. The
// signing secret is deliberately absent: it appears only in the create and
// rotate-secret responses, which decode into webhookEndpointCreated below.
type webhookEndpoint struct {
	ID                  string   `json:"id"`
	URL                 string   `json:"url"`
	Description         string   `json:"description"`
	EventTypes          []string `json:"event_types"`
	Status              string   `json:"status"`
	ConsecutiveFailures int      `json:"consecutive_failures"`
	DisabledReason      string   `json:"disabled_reason"`
	InsertedAt          string   `json:"inserted_at"`
}

// webhookEndpointCreated is the only shape that carries the secret. Decoding
// the wrong one loses it forever, the same trap `keys create` documents.
type webhookEndpointCreated struct {
	Data   webhookEndpoint `json:"data"`
	Secret string          `json:"secret"`
}

type webhookDelivery struct {
	ID           string `json:"id"`
	EventID      string `json:"event_id"`
	EventType    string `json:"event_type"`
	Attempt      int    `json:"attempt"`
	StatusCode   int    `json:"status_code"`
	DurationMs   int    `json:"duration_ms"`
	Error        string `json:"error"`
	ResponseBody string `json:"response_body"`
	InsertedAt   string `json:"inserted_at"`
}

func init() {
	webhooksCmd := &cobra.Command{
		Use:   "webhooks",
		Short: "Manage outbound webhook endpoints",
		Long: `Endpoints Fountain POSTs conversation lifecycle events to.

Events are signed with an HMAC secret shown once, at creation and at each
rotation. Payloads carry ids and a stage, never conversation output: read
the transcript with ` + "`fountain conv logs`" + ` or GET /api/conversations/:id/events.`,
	}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List webhook endpoints",
		RunE:  func(cmd *cobra.Command, args []string) error { return webhooksList(cmd) },
	}
	listCmd.Flags().Bool("json", false, "output JSON")

	createCmd := &cobra.Command{
		Use:   "create <url>",
		Short: "Create a webhook endpoint",
		Args:  cobra.ExactArgs(1),
		RunE:  func(cmd *cobra.Command, args []string) error { return webhooksCreate(cmd, args[0]) },
	}
	createCmd.Flags().String("description", "", "what this endpoint is for")
	createCmd.Flags().StringSlice("event", nil,
		"event to subscribe to; repeatable. Defaults to conversation.turn.done, conversation.turn.failed and conversation.provision.failed")

	deliveriesCmd := &cobra.Command{
		Use:   "deliveries <id>",
		Short: "Show recent delivery attempts",
		Args:  cobra.ExactArgs(1),
		RunE:  func(cmd *cobra.Command, args []string) error { return webhooksDeliveries(cmd, args[0]) },
	}
	deliveriesCmd.Flags().Bool("json", false, "output JSON")
	deliveriesCmd.Flags().Int("limit", 20, "how many attempts to show")

	webhooksCmd.AddCommand(
		listCmd,
		createCmd,
		deliveriesCmd,
		&cobra.Command{
			Use:   "show <id>",
			Short: "Show a webhook endpoint",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return webhooksShow(args[0]) },
		},
		&cobra.Command{
			Use:   "delete <id>",
			Short: "Delete a webhook endpoint",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return webhooksDelete(args[0]) },
		},
		&cobra.Command{
			Use:   "test <id>",
			Short: "Send a test event",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return webhooksTest(args[0]) },
		},
		&cobra.Command{
			Use:   "rotate-secret <id>",
			Short: "Mint a new signing secret",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return webhooksRotate(args[0]) },
		},
		&cobra.Command{
			Use:   "pause <id>",
			Short: "Stop delivering to an endpoint",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return webhooksSetStatus(args[0], "disabled") },
		},
		&cobra.Command{
			Use:   "resume <id>",
			Short: "Start delivering to an endpoint again",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return webhooksSetStatus(args[0], "active") },
		},
		&cobra.Command{
			Use:   "redeliver <id> <delivery-id>",
			Short: "Send one recorded event again",
			Args:  cobra.ExactArgs(2),
			RunE: func(cmd *cobra.Command, args []string) error {
				return webhooksRedeliver(args[0], args[1])
			},
		},
	)
	rootCmd.AddCommand(webhooksCmd)
}

func webhooksList(cmd *cobra.Command) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	c := activeClient()
	var resp struct {
		Data []webhookEndpoint `json:"data"`
	}
	if err := c.Get("/webhooks", &resp); err != nil {
		Fatal(err.Error())
	}
	if jsonOut {
		return output.PrintJSON(resp.Data)
	}
	rows := make([][]string, 0, len(resp.Data))
	for _, e := range resp.Data {
		rows = append(rows, []string{e.ID, e.URL, e.Status, strings.Join(e.EventTypes, ",")})
	}
	output.Table([]string{"id", "url", "status", "events"}, rows)
	return nil
}

func webhooksCreate(cmd *cobra.Command, url string) error {
	description, _ := cmd.Flags().GetString("description")
	events, _ := cmd.Flags().GetStringSlice("event")

	body := map[string]any{"url": url}
	if description != "" {
		body["description"] = description
	}
	if len(events) > 0 {
		body["event_types"] = events
	}

	c := activeClient()
	var resp webhookEndpointCreated
	if err := c.Post("/webhooks", body, &resp); err != nil {
		Fatal(err.Error())
	}
	if resp.Secret == "" {
		Fatalf("unexpected response: no secret field (id=%q)", resp.Data.ID)
	}
	printWebhookSecret(resp)
	return nil
}

func webhooksShow(id string) error {
	c := activeClient()
	var resp struct {
		Data webhookEndpoint `json:"data"`
	}
	if err := c.Get("/webhooks/"+id, &resp); err != nil {
		Fatal(err.Error())
	}
	return output.PrintJSON(resp.Data)
}

func webhooksDelete(id string) error {
	fmt.Printf("Delete webhook endpoint %s? Its delivery log goes with it. [y/N] ", id)
	if !confirmed() {
		fmt.Println("Aborted.")
		return nil
	}
	c := activeClient()
	if err := c.Delete("/webhooks/"+id, nil); err != nil {
		Fatal(err.Error())
	}
	fmt.Println("Deleted.")
	return nil
}

func webhooksTest(id string) error {
	c := activeClient()
	var resp struct {
		Queued    bool   `json:"queued"`
		EventType string `json:"event_type"`
	}
	if err := c.Post("/webhooks/"+id+"/test", map[string]any{}, &resp); err != nil {
		Fatal(err.Error())
	}
	fmt.Printf("Queued a %s event. See `fountain webhooks deliveries %s` for the result.\n",
		resp.EventType, id)
	return nil
}

func webhooksRotate(id string) error {
	fmt.Printf("Rotate the secret for %s? The old one stops verifying immediately. [y/N] ", id)
	if !confirmed() {
		fmt.Println("Aborted.")
		return nil
	}
	c := activeClient()
	var resp webhookEndpointCreated
	if err := c.Post("/webhooks/"+id+"/rotate-secret", map[string]any{}, &resp); err != nil {
		Fatal(err.Error())
	}
	if resp.Secret == "" {
		Fatalf("unexpected response: no secret field (id=%q)", resp.Data.ID)
	}
	printWebhookSecret(resp)
	return nil
}

func webhooksSetStatus(id, status string) error {
	c := activeClient()
	var resp struct {
		Data webhookEndpoint `json:"data"`
	}
	if err := c.Patch("/webhooks/"+id, map[string]any{"status": status}, &resp); err != nil {
		Fatal(err.Error())
	}
	fmt.Printf("%s is now %s.\n", resp.Data.URL, resp.Data.Status)
	return nil
}

func webhooksDeliveries(cmd *cobra.Command, id string) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	limit, _ := cmd.Flags().GetInt("limit")

	c := activeClient()
	var resp struct {
		Data []webhookDelivery `json:"data"`
	}
	if err := c.Get(fmt.Sprintf("/webhooks/%s/deliveries?limit=%d", id, limit), &resp); err != nil {
		Fatal(err.Error())
	}
	if jsonOut {
		return output.PrintJSON(resp.Data)
	}
	rows := make([][]string, 0, len(resp.Data))
	for _, d := range resp.Data {
		result := fmt.Sprintf("%d", d.StatusCode)
		if d.StatusCode == 0 {
			result = "failed"
		}
		detail := d.Error
		if detail == "" {
			detail = d.ResponseBody
		}
		rows = append(rows, []string{
			d.ID, d.EventType, fmt.Sprintf("%d", d.Attempt), result,
			fmt.Sprintf("%dms", d.DurationMs), truncate(detail, 48),
		})
	}
	output.Table([]string{"id", "event", "try", "result", "took", "detail"}, rows)
	return nil
}

func webhooksRedeliver(id, deliveryID string) error {
	c := activeClient()
	var resp struct {
		Queued bool `json:"queued"`
	}
	path := fmt.Sprintf("/webhooks/%s/deliveries/%s/redeliver", id, deliveryID)
	if err := c.Post(path, map[string]any{}, &resp); err != nil {
		Fatal(err.Error())
	}
	fmt.Println("Queued again.")
	return nil
}

func printWebhookSecret(resp webhookEndpointCreated) {
	fmt.Println()
	fmt.Println("╭────────────────────────────────────────────────────────────────╮")
	fmt.Println("│  Save this secret — it will not be shown again.                │")
	fmt.Println("╰────────────────────────────────────────────────────────────────╯")
	fmt.Println()
	fmt.Println(resp.Secret)
	fmt.Println()
	fmt.Printf("Endpoint: %s\n", resp.Data.ID)
	fmt.Printf("URL:      %s\n", resp.Data.URL)
	fmt.Printf("Events:   %s\n", strings.Join(resp.Data.EventTypes, ", "))
	fmt.Println()
}

func confirmed() bool {
	r := bufio.NewReader(os.Stdin)
	answer, _ := r.ReadString('\n')
	answer = strings.ToLower(strings.TrimSpace(answer))
	return answer == "y" || answer == "yes"
}

func truncate(s string, n int) string {
	s = strings.ReplaceAll(strings.TrimSpace(s), "\n", " ")
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}
