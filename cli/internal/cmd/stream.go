package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	"github.com/BinaryBourbon/fountain/cli/internal/sse"
)

// streamOpener opens an SSE body, resuming after lastEventID when non-empty.
//
// Behind an interface so the reconnect logic can be tested without a server:
// the bug this file exists to fix only appears across a disconnect, which is
// exactly the part that is awkward to reach through the real client.
type streamOpener func(ctx context.Context, lastEventID string) (io.ReadCloser, error)

const (
	// How long to wait with no bytes at all before giving up. The server closes
	// its SSE loop after 60s of quiet, so this has to be comfortably longer than
	// that or every reconnect would look like an idle stream.
	defaultStreamIdle = 30 * time.Minute

	// Consecutive failures to reopen the stream before giving up. Transport
	// errors are usually transient; a server that is genuinely gone will exhaust
	// these quickly.
	maxReconnectAttempts = 5
)

var errIdleTimeout = errors.New("no output received")

// reconnectBackoff is a variable so tests do not have to sit through real
// sleeps to exercise the retry path.
var reconnectBackoff = func(attempt int) time.Duration {
	return time.Duration(attempt) * time.Second
}

// streamIdleTimeout allows the wait to be widened or narrowed without a rebuild.
func streamIdleTimeout() time.Duration {
	if v := os.Getenv("FOUNTAIN_STREAM_IDLE_TIMEOUT"); v != "" {
		if secs, err := strconv.Atoi(v); err == nil && secs > 0 {
			return time.Duration(secs) * time.Second
		}
	}
	return defaultStreamIdle
}

// followStream consumes an SSE stream until the turn reaches a terminal state,
// reconnecting when the server closes the connection.
//
// The bug this replaces: the old loop treated io.EOF as success and returned
// nil. The server closes its SSE loop after 60 seconds of quiet, so any turn
// that thought for longer than a minute without emitting output made the CLI
// exit silently, reporting success while the agent was still working. For a
// product whose normal case is a long-running agent, that is the worst possible
// failure — it is indistinguishable from the turn actually finishing.
//
// A disconnect now resumes from the last event id, so output produced while
// disconnected is replayed rather than lost, and only a terminal event or a
// genuine timeout ends the loop.
func followStream(open streamOpener, idle time.Duration, convID string) error {
	lastEventID := ""
	failures := 0

	for {
		done, resumeID, err := streamOnce(open, lastEventID, idle)
		if resumeID != "" {
			lastEventID = resumeID
		}

		switch {
		case done:
			return nil

		case errors.Is(err, errIdleTimeout):
			// Explicit, rather than the old silent success.
			return fmt.Errorf(
				"no output for %s — the turn may still be running; reattach with `fountain conv stream %s`",
				idle, convID,
			)

		case err != nil:
			failures++
			if failures >= maxReconnectAttempts {
				return fmt.Errorf("stream failed after %d attempts: %w", failures, err)
			}
			// Linear backoff: enough to ride out a redeploy without hammering.
			time.Sleep(reconnectBackoff(failures))

		default:
			// Clean EOF with no terminal event: the server closed an idle
			// stream. Reconnect and keep waiting.
			failures = 0
		}
	}
}

// streamOnce reads one connection to completion. It returns whether a terminal
// event was seen and the id to resume from if the connection drops.
func streamOnce(open streamOpener, lastEventID string, idle time.Duration) (bool, string, error) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	body, err := open(ctx, lastEventID)
	if err != nil {
		return false, "", err
	}
	defer body.Close()

	// Idle watchdog. A blocking Read cannot be given a deadline directly, so a
	// separate goroutine cancels the request context if nothing arrives.
	activity := make(chan struct{}, 1)
	idled := make(chan struct{})
	go watchIdle(ctx, cancel, activity, idled, idle)

	buf := make([]byte, 8192)
	var pending bytes.Buffer
	resumeID := lastEventID

	for {
		n, readErr := body.Read(buf)
		if n > 0 {
			select {
			case activity <- struct{}{}:
			default:
			}

			pending.Write(buf[:n])
			events, leftover := sse.Feed(pending.String())
			pending.Reset()
			pending.WriteString(leftover)

			for _, ev := range events {
				if ev.ID > 0 {
					resumeID = strconv.Itoa(ev.ID)
				}
				if handleEvent(ev) {
					return true, resumeID, nil
				}
			}
		}

		if readErr != nil {
			select {
			case <-idled:
				return false, resumeID, errIdleTimeout
			default:
			}
			if errors.Is(readErr, io.EOF) {
				return false, resumeID, nil
			}
			return false, resumeID, readErr
		}
	}
}

// watchIdle cancels the request context when nothing has arrived for `idle`.
// Cancelling is what actually unblocks the pending Read — closing `idled` alone
// would leave a genuinely stalled stream hanging forever, which is the failure
// this whole change is meant to remove.
func watchIdle(
	ctx context.Context,
	cancel context.CancelFunc,
	activity <-chan struct{},
	idled chan<- struct{},
	idle time.Duration,
) {
	timer := time.NewTimer(idle)
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-activity:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(idle)
		case <-timer.C:
			close(idled)
			cancel()
			return
		}
	}
}
