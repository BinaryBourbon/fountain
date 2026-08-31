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
	loginCmd := &cobra.Command{
		Use:   "login",
		Short: "Authenticate and save credentials",
		RunE: func(cmd *cobra.Command, args []string) error {
			withAPIKey, _ := cmd.Flags().GetBool("api-key")
			if withAPIKey {
				return authLoginAPIKey()
			}
			return authLogin()
		},
	}
	loginCmd.Flags().Bool("api-key", false,
		"paste an API key instead of email + password (for accounts that sign in with GitHub)")
	authCmd.AddCommand(
		loginCmd,
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
		// The server answers every bad credential with the same 401 on
		// purpose (anti-enumeration, #324) — an account created with "Sign
		// up with GitHub" has no password and lands here too, so the hint
		// has to live on this side.
		if resp.StatusCode == http.StatusUnauthorized {
			Fatalf("login failed (HTTP %d): %s\n\n"+
				"If you signed up with GitHub, your account has no password.\n"+
				"Create an API key in the console (%s/api-keys), then run:\n\n"+
				"  fountain auth login --api-key",
				resp.StatusCode, respBody, base)
		}
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

// authLoginAPIKey is `auth login --api-key`: the login path for accounts that
// sign in with GitHub and therefore have no password to exchange at
// /api/auth/token (#1305). The key is prompted for, never taken as a flag
// value, so it stays out of shell history; the prompt is hidden on a TTY and
// falls back to a plain stdin read so `echo $KEY | fountain auth login
// --api-key` works in scripts.
func authLoginAPIKey() error {
	opts := activeOpts()
	profile := credentials.ProfileName(opts)
	base := config.BaseURL(opts)

	key, err := promptPassword("API key: ")
	if err != nil {
		return err
	}
	key = strings.TrimSpace(key)
	if key == "" {
		Fatal("no API key given. Create one in the console at " + base + "/api-keys.")
	}

	// Validate before writing, so a mispasted key fails here rather than on
	// the next command.
	me, err := fetchAuthMe(base, key)
	if err != nil {
		Fatalf("could not verify the API key against %s: %v", base, err)
	}

	if err := credentials.WriteProfile(profile, map[string]string{
		"api_key":  key,
		"base_url": base,
	}); err != nil {
		return err
	}

	fmt.Printf("Logged in as %s. Credentials written to ~/.fountain/credentials (profile: %s).\n", me.Email, profile)
	return nil
}

// fetchAuthMe checks a raw key against GET /api/auth/me. It cannot go through
// api.Client, which resolves its key from the environment and the credentials
// file — exactly what this key has not been written to yet.
func fetchAuthMe(base, key string) (*authMe, error) {
	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, base+"/api/auth/me", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+key)

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == http.StatusUnauthorized {
		return nil, fmt.Errorf("the server rejected the key (HTTP 401)")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, respBody)
	}

	var me authMe
	if err := json.Unmarshal(respBody, &me); err != nil {
		return nil, fmt.Errorf("unexpected response: %s", respBody)
	}
	return &me, nil
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

// authMe mirrors FountainWeb.AuthMeController.show/2
// (apps/fountain/lib/fountain_web/controllers/auth_me_controller.ex): a flat
// object, no `data` envelope.
type authMe struct {
	ID    string `json:"id"`
	Email string `json:"email"`
	Role  string `json:"role"`
}

func authWhoami() error {
	c := activeClient()
	profile := credentials.ProfileName(activeOpts())

	var out authMe
	if err := c.Get("/auth/me", &out); err != nil {
		if api.StatusCode(err) == 401 {
			Fatalf("not authenticated for profile '%s'. Run `fountain auth login --profile %s`.", profile, profile)
		}
		Fatal(err.Error())
	}
	fmt.Printf("email: %s\n", out.Email)
	fmt.Printf("role:  %s\n", out.Role)
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
