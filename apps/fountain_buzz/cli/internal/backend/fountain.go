package backend

import (
	"fmt"
	"regexp"

	"github.com/BinaryBourbon/fountain/cli/api"
)

var uuidRe = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// apiFountain talks to a Fountain instance over its HTTP API using the ambient
// credentials (env / the fountain CLI creds file) — never provider_config.
type apiFountain struct {
	c *api.Client
}

// NewFountain returns a Fountain backed by the given API client.
func NewFountain(c *api.Client) Fountain { return &apiFountain{c: c} }

func (a *apiFountain) ResolveAgent(sel string) (string, error) {
	if uuidRe.MatchString(sel) {
		return sel, nil
	}

	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := a.c.Get("/agents", &resp); err != nil {
		return "", err
	}

	for _, ag := range resp.Data {
		if fmt.Sprint(ag["name"]) == sel {
			return fmt.Sprint(ag["id"]), nil
		}
	}
	return "", fmt.Errorf("no agent named %q", sel)
}

func (a *apiFountain) ResolveEnvironment(sel string) (string, error) {
	if uuidRe.MatchString(sel) {
		return sel, nil
	}

	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := a.c.Get("/environments", &resp); err != nil {
		return "", err
	}

	for _, env := range resp.Data {
		if fmt.Sprint(env["name"]) == sel {
			return fmt.Sprint(env["id"]), nil
		}
	}
	return "", fmt.Errorf("no environment named %q", sel)
}

func (a *apiFountain) Provision(body ProvisionBody) (string, error) {
	var out struct {
		Data struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := a.c.Post("/buzz/agents", body, &out); err != nil {
		return "", err
	}
	if out.Data.ID == "" {
		return "", fmt.Errorf("provision returned no id")
	}
	return out.Data.ID, nil
}
