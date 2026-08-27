package runner

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"
)

// fcAPI drives one microVM through the Firecracker HTTP API, which listens
// on a unix socket rather than a port. Everything here is one VM's control
// plane; the sandbox semantics are in firecracker.go.
type fcAPI struct {
	sock   string
	client *http.Client
}

func newFCAPI(sock string) *fcAPI {
	return &fcAPI{
		sock: sock,
		client: &http.Client{
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					return (&net.Dialer{}).DialContext(ctx, "unix", sock)
				},
			},
		},
	}
}

// fcFault is the shape Firecracker refuses in.
type fcFault struct {
	FaultMessage string `json:"fault_message"`
}

func (a *fcAPI) do(ctx context.Context, method, path string, body any) error {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://localhost"+path, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := a.client.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	var fault fcFault
	if json.Unmarshal(raw, &fault) == nil && fault.FaultMessage != "" {
		return fmt.Errorf("firecracker %s %s: %s", method, path, fault.FaultMessage)
	}
	return fmt.Errorf("firecracker %s %s: HTTP %d: %s", method, path, resp.StatusCode, bytes.TrimSpace(raw))
}

// instanceState is Firecracker's own view: "Not started", "Running" or
// "Paused". It is the source of truth for the sandbox's status, rather than
// anything the daemon remembers, so a VM someone paused by hand still reads
// correctly.
func (a *fcAPI) instanceState(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://localhost/", nil)
	if err != nil {
		return "", err
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return "", err
	}
	defer func() { _ = resp.Body.Close() }()
	var info struct {
		State string `json:"state"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8192)).Decode(&info); err != nil {
		return "", err
	}
	return info.State, nil
}

// waitAPI blocks until the API socket answers, which is how the daemon knows
// the firecracker process has finished starting up and will accept config.
func (a *fcAPI) waitAPI(ctx context.Context) error {
	for {
		if _, err := a.instanceState(ctx); err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("firecracker API socket %s never answered: %w", a.sock, ctx.Err())
		case <-time.After(10 * time.Millisecond):
		}
	}
}

// ── the calls the daemon makes, in boot order ────────────────────────────────

func (a *fcAPI) setMachineConfig(ctx context.Context, vcpus, memMiB int) error {
	return a.do(ctx, http.MethodPut, "/machine-config", map[string]any{
		"vcpu_count":   vcpus,
		"mem_size_mib": memMiB,
	})
}

func (a *fcAPI) setBootSource(ctx context.Context, kernel, bootArgs string) error {
	return a.do(ctx, http.MethodPut, "/boot-source", map[string]any{
		"kernel_image_path": kernel,
		"boot_args":         bootArgs,
	})
}

func (a *fcAPI) setRootDrive(ctx context.Context, path string) error {
	return a.do(ctx, http.MethodPut, "/drives/rootfs", map[string]any{
		"drive_id":       "rootfs",
		"path_on_host":   path,
		"is_root_device": true,
		"is_read_only":   false,
	})
}

func (a *fcAPI) setNetwork(ctx context.Context, tap, mac string) error {
	return a.do(ctx, http.MethodPut, "/network-interfaces/eth0", map[string]any{
		"iface_id":      "eth0",
		"host_dev_name": tap,
		"guest_mac":     mac,
	})
}

// setVsock is what makes the guest reachable. Firecracker presents the
// guest's listening ports on the host as a unix socket: connect to udsPath,
// send "CONNECT <port>\n", and the stream is the guest's. That is why the
// host side of this backend needs no AF_VSOCK support of its own.
func (a *fcAPI) setVsock(ctx context.Context, cid int, udsPath string) error {
	return a.do(ctx, http.MethodPut, "/vsock", map[string]any{
		"vsock_id":  "vsock0",
		"guest_cid": cid,
		"uds_path":  udsPath,
	})
}

func (a *fcAPI) start(ctx context.Context) error {
	return a.do(ctx, http.MethodPut, "/actions", map[string]any{"action_type": "InstanceStart"})
}

func (a *fcAPI) pause(ctx context.Context) error {
	return a.do(ctx, http.MethodPatch, "/vm", map[string]any{"state": "Paused"})
}

func (a *fcAPI) resume(ctx context.Context) error {
	return a.do(ctx, http.MethodPatch, "/vm", map[string]any{"state": "Resumed"})
}
