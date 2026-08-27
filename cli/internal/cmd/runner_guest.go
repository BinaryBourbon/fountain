package cmd

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/BinaryBourbon/fountain/cli/internal/runner"
	"github.com/spf13/cobra"
)

var (
	guestRoot     string
	guestPort     int
	guestLogLevel string
)

func init() {
	guestCmd := &cobra.Command{
		Use:   "runner-guest",
		Short: "Serve one sandbox from inside a Firecracker microVM",
		Long: `Run the in-VM half of a Fountain runner.

This is not a command to type at a prompt. It belongs in the base rootfs of
a runner using --backend firecracker, started at boot by the guest's init:
the daemon on the host boots a microVM from that image and talks to this
agent over vsock, and a VM whose agent never answers is refused as a sandbox
rather than accepted and left to hang.

It serves exactly one sandbox, --root/sprite, which is /home/sprite. What it
serves it with is the ordinary runner backend, so a command in here behaves
as it does on a trusted-mode runner. The isolation is the machine boundary
around this process, not anything this process does.

A systemd unit is all it needs:

    [Unit]
    Description=Fountain runner guest agent
    After=network.target

    [Service]
    ExecStart=/usr/local/bin/fountain runner-guest
    Restart=always

    [Install]
    WantedBy=multi-user.target`,
		RunE: func(cmd *cobra.Command, args []string) error { return runRunnerGuest() },
	}
	guestCmd.Flags().StringVar(&guestRoot, "root", "/home", "parent of the sandbox directory; the sandbox is <root>/sprite")
	guestCmd.Flags().IntVar(&guestPort, "port", runner.GuestPort, "vsock port to listen on")
	guestCmd.Flags().StringVar(&guestLogLevel, "log-level", "info", "debug|info|warn|error")
	rootCmd.AddCommand(guestCmd)
}

func runRunnerGuest() error {
	var level slog.Level
	if err := level.UnmarshalText([]byte(guestLogLevel)); err != nil {
		return fmt.Errorf("--log-level: %w", err)
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))

	// The sandbox directory is the agent's memory across turns, and on a
	// fresh rootfs it does not exist yet. Creating it here means a base
	// image only has to contain the binary.
	home := filepath.Join(guestRoot, "sprite")
	if err := os.MkdirAll(home, 0o700); err != nil {
		return fmt.Errorf("create %s: %w", home, err)
	}

	backend, err := runner.NewProcess(guestRoot, log)
	if err != nil {
		return err
	}
	d := runner.NewWithBackend(backend, log)

	ln, err := runner.ListenVsock(uint32(guestPort))
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	log.Info("runner-guest: listening", "vsock_port", guestPort, "sandbox", home)
	err = runner.ServeGuest(ctx, ln, d, log)
	d.StopAll()
	return err
}
