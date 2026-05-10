package cmd

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/BinaryBourbon/fountain/cli/internal/api"
	"github.com/BinaryBourbon/fountain/cli/internal/config"
	"github.com/BinaryBourbon/fountain/cli/internal/credentials"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func init() {
	authCmd := &cobra.Command{
		Use:   "auth",
		Short: "Authenticate against the Fountain API",
	}
	authCmd.AddCommand(
		&cobra.Command{
			Use:   "login",
			Short: "Authenticate and save credentials",
			RunE:  func(cmd *cobra.Command, args []string) error { return authLogin() },
		},
		&cobra.Command{
			Use:   "logout",
			Short: "Remove saved credentials",
			RunE:  func(cmd *cobra.Command, args []string) error { return authLogout() },
		},
		&cobra.Command{
			Use:   "whoami",
			Short: "Print current user info",
			RunE:  func(cmd *cobra.Command, args []string) error { return authWhoami() },
		},
	)
	rootCmd.AddCommand(authCmd)
}

func authLogin() error {
	opts := activeOpts()
	profile := credentials.ProfileName(opts)

	email, err := promptLine("Email: ")
	if err != nil {
		return err
	}
	password, err := promptPassword("Password: ")
	if err != nil {
		return err
	}

	base := config.BaseURL(opts)
	body, err := json.Marshal(map[string]string{"email": email, "password": password})
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, base+"/api/auth/token", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		Fatalf("login failed (HTTP %d): %s", resp.StatusCode, respBody)
	}

	key := extractAPIKey(respBody)
	if key == "" {
		Fatalf("unexpected login response: %s", respBody)
	}

	if err := credentials.WriteProfile(profile, map[string]string{
		"api_key":  key,
		"base_url": base,
	}); err != nil {
		return err
	}

	fmt.Printf("Logged in as %s. Credentials written to ~/.fountain/credentials (profile: %s).\n", email, profile)
	return nil
}

// extractAPIKey accepts any of the four shapes the server has returned:
// {data:{api_key}}, {data:{token}}, {api_key}, {token}.
func extractAPIKey(body []byte) string {
	var top struct {
		Data struct {
			APIKey string `json:"api_key"`
			Token  string `json:"token"`
		} `json:"data"`
		APIKey string `json:"api_key"`
		Token  string `json:"token"`
	}
	if json.Unmarshal(body, &top) != nil {
		return ""
	}
	switch {
	case top.Data.APIKey != "":
		return top.Data.APIKey
	case top.Data.Token != "":
		return top.Data.Token
	case top.APIKey != "":
		return top.APIKey
	case top.Token != "":
		return top.Token
	}
	return ""
}

func authLogout() error {
	profile := credentials.ProfileName(activeOpts())
	if err := credentials.DeleteProfile(profile); err != nil {
		return err
	}
	fmt.Printf("Profile '%s' removed from ~/.fountain/credentials.\n", profile)
	return nil
}

func authWhoami() error {
	c := activeClient()
	profile := credentials.ProfileName(activeOpts())

	var out struct {
		Data struct {
			Email string `json:"email"`
			Role  string `json:"role"`
		} `json:"data"`
	}
	if err := c.Get("/auth/me", &out); err != nil {
		if api.StatusCode(err) == 401 {
			Fatalf("not authenticated for profile '%s'. Run `fountain auth login --profile %s`.", profile, profile)
		}
		Fatal(err.Error())
	}
	fmt.Printf("email: %s\n", out.Data.Email)
	fmt.Printf("role:  %s\n", out.Data.Role)
	return nil
}

func promptLine(label string) (string, error) {
	fmt.Print(label)
	r := bufio.NewReader(os.Stdin)
	line, err := r.ReadString('\n')
	if err != nil && err != io.EOF {
		return "", err
	}
	return strings.TrimRight(line, "\r\n"), nil
}

func promptPassword(label string) (string, error) {
	fmt.Print(label)
	if term.IsTerminal(int(os.Stdin.Fd())) {
		buf, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Println()
		if err != nil {
			return "", err
		}
		return strings.TrimRight(string(buf), "\r\n"), nil
	}
	// Non-TTY: fall back to plain read so piped tests work.
	return promptLine("")
}
