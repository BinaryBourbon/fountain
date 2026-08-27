package runner

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"sync"
)

// GuestListener is the vsock socket `fountain runner-guest` waits on. It is
// an interface rather than a net.Listener because Go's net package has no
// AF_VSOCK support, so the real one is built on raw syscalls — and because
// a pipe stands in for it in the tests.
type GuestListener interface {
	Accept() (io.ReadWriteCloser, error)
	Close() error
}

// ServeGuest runs the daemon's protocol over a listener, inside a microVM.
//
// The guest agent is the same daemon: it reads the same frames and answers
// them with the same Process backend, rooted at /home so that its one
// sandbox, "sprite", is /home/sprite. Nothing about a command running in
// here differs from a command running on a trusted-mode runner, which is
// the point — the isolation is the machine boundary, not a second
// implementation of exec.
//
// Sessions belong to the agent, not to a connection, so a host that
// reconnects after a Fountain deploy re-attaches to the turn still running
// and replays its journal from byte zero.
func ServeGuest(ctx context.Context, ln GuestListener, d *Daemon, log Logger) error {
	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go serveGuestConn(ctx, conn, d, log)
	}
}

func serveGuestConn(ctx context.Context, conn io.ReadWriteCloser, d *Daemon, log Logger) {
	defer func() { _ = conn.Close() }()
	emit := &guestEmitter{w: conn}
	reader := bufio.NewReader(conn)
	for {
		line, err := reader.ReadString('\n')
		if len(line) > 0 {
			var req Request
			if err := json.Unmarshal([]byte(line), &req); err != nil {
				log.Warn("runner-guest: bad frame", "err", err)
			} else {
				go guestDispatch(d, req, emit, log)
			}
		}
		if err != nil {
			if !errors.Is(err, io.EOF) && ctx.Err() == nil {
				log.Debug("runner-guest: connection ended", "err", err)
			}
			return
		}
	}
}

// guestDispatch answers one request. The order it writes in is the order
// Fountain depends on and the host forwards unchanged: the reply first, the
// journal replay after it, live frames after that.
func guestDispatch(d *Daemon, req Request, emit *guestEmitter, log Logger) {
	// ping is the agent's own liveness answer, not part of the sandbox
	// contract: the host uses it to tell a booted VM from a booted VM that
	// never started its agent.
	if req.Op == "ping" {
		emit.Emit(Reply(req.ID, map[string]any{"agent": "fountain runner-guest"}, nil))
		return
	}
	result, after, err := d.Handle(req, emit)
	if err != nil {
		var op *OpError
		if !errors.As(err, &op) || op.Code == "unavailable" || op.Code == "provider" {
			log.Warn("runner-guest: request failed", "op", req.Op, "err", err)
		}
	}
	emit.Emit(Reply(req.ID, result, err))
	if after != nil {
		after()
	}
}

// guestEmitter serializes frames onto one host connection.
type guestEmitter struct {
	mu sync.Mutex
	w  io.Writer
}

func (e *guestEmitter) Emit(f Frame) {
	e.mu.Lock()
	defer e.mu.Unlock()
	_, _ = e.w.Write(append(Marshal(f), '\n'))
}
