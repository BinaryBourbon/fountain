// Package api is a thin HTTP client for the Fountain API.
//
// All requests are prefixed with /api and carry a Bearer token resolved
// from FountainCli config (env vars, then ~/.fountain/credentials).
package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/BinaryBourbon/fountain/cli/internal/config"
	"github.com/BinaryBourbon/fountain/cli/internal/credentials"
)

// HTTPError carries the status code and decoded body for non-2xx responses.
type HTTPError struct {
	Status int
	Body   any // map/array/string depending on parse
}

func (e *HTTPError) Error() string {
	if e.Body == nil {
		return fmt.Sprintf("http %d", e.Status)
	}
	return fmt.Sprintf("http %d: %v", e.Status, e.Body)
}

// Client wraps the HTTP client and credential resolution.
type Client struct {
	HTTP *http.Client
	Opts credentials.Opts
}

// New returns a Client bound to the active profile.
func New(opts credentials.Opts) *Client {
	return &Client{
		HTTP: &http.Client{Timeout: 60 * time.Second},
		Opts: opts,
	}
}

// BaseURL returns the resolved base URL (no trailing slash).
func (c *Client) BaseURL() string { return config.BaseURL(c.Opts) }

// Token returns the API token, or an error if unconfigured.
func (c *Client) Token() (string, error) { return config.APIKey(c.Opts) }

// Get performs GET /api<path> and decodes JSON into out (may be nil to discard).
func (c *Client) Get(path string, out any) error {
	return c.do(http.MethodGet, path, nil, out)
}

// Post performs POST /api<path> with a JSON body.
func (c *Client) Post(path string, body, out any) error {
	return c.do(http.MethodPost, path, body, out)
}

// Put performs PUT /api<path> with a JSON body.
func (c *Client) Put(path string, body, out any) error {
	return c.do(http.MethodPut, path, body, out)
}

// Delete performs DELETE /api<path>.
func (c *Client) Delete(path string, out any) error {
	return c.do(http.MethodDelete, path, nil, out)
}

func (c *Client) do(method, path string, body, out any) error {
	token, err := c.Token()
	if err != nil {
		return err
	}
	url := c.BaseURL() + "/api" + path

	var rdr io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rdr = bytes.NewReader(buf)
	}

	req, err := http.NewRequestWithContext(context.Background(), method, url, rdr)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var decoded any
		if len(respBody) > 0 {
			if json.Unmarshal(respBody, &decoded) != nil {
				decoded = string(respBody)
			}
		}
		return &HTTPError{Status: resp.StatusCode, Body: decoded}
	}

	if out == nil || len(respBody) == 0 {
		return nil
	}
	return json.Unmarshal(respBody, out)
}

// NewStreamRequest returns an *http.Request for an SSE endpoint.
// The caller is responsible for executing it and parsing the body.
func (c *Client) NewStreamRequest(ctx context.Context, path, lastEventID string) (*http.Request, error) {
	token, err := c.Token()
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.BaseURL()+"/api"+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "text/event-stream")
	if lastEventID != "" {
		req.Header.Set("Last-Event-ID", lastEventID)
	}
	return req, nil
}

// StatusCode extracts the status code from an error if it is an HTTPError.
func StatusCode(err error) int {
	if he, ok := err.(*HTTPError); ok {
		return he.Status
	}
	return 0
}
