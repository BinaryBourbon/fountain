package acp

import (
	"context"
	"encoding/json"
)

type cancelParams struct {
	SessionID string `json:"sessionId"`
}

// cancel stops the running turn.
//
// Three properties, each of which is a way this could go wrong:
//
// **It answers nothing.** JSON-RPC forbids a response to a notification, and
// ACP puts the answer somewhere better anyway — the pending `session/prompt`
// returns `cancelled` when the interrupted stage reaches its follow. An editor
// therefore learns the turn stopped from the request it is already waiting on.
//
// **It can only work because requests dispatch concurrently.** A connection
// that read one message at a time would not reach this notification until the
// prompt it is meant to stop had already finished.
//
// **A turn that already ended is not an error.** The server answers 409 for a
// conversation with no turn running, which is the normal outcome of a cancel
// that raced the agent finishing. Reporting it would be reporting a failure
// that did not happen.
func (a *Agent) cancel(ctx context.Context, raw json.RawMessage) {
	var params cancelParams
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &params); err != nil {
			a.log.Warn("session/cancel: bad params", "err", err)
			return
		}
	}

	sess, ok := a.sessions.get(params.SessionID)
	if !ok {
		a.log.Warn("session/cancel for an unknown session", "sessionId", params.SessionID)
		return
	}

	a.log.Info("cancelling", "sessionId", sess.ID)
	if err := a.api.Interrupt(ctx, sess.ID); err != nil {
		// Logged, not raised: there is nobody to raise it to. If the interrupt
		// genuinely failed the turn keeps running and the prompt will report
		// whatever it actually does — which is the truth either way.
		a.log.Warn("interrupt failed", "sessionId", sess.ID, "err", err)
	}
}
