package acp

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
)

// ErrAlreadyResolved is what an API implementation returns (wrapped) when the
// server says a permission request has already been answered — by another
// attached client, by the ask timeout, or by the turn ending. #940 makes
// first-answer-wins the contract, so this is an outcome rather than a fault.
var ErrAlreadyResolved = errors.New("the permission request was already resolved")

// IsAlreadyResolved reports whether err is that outcome.
func IsAlreadyResolved(err error) bool { return errors.Is(err, ErrAlreadyResolved) }

// Requester sends a request to the connected client and waits for its answer.
// *Conn implements it; the agent holds it through the same field as Notifier,
// because the one client that can answer a permission request is the one the
// updates are going to.
type Requester interface {
	Request(ctx context.Context, method string, params any) (json.RawMessage, error)
}

// permissionOutcome is the result shape ACP defines for
// `session/request_permission`: `{"outcome": {"outcome": "selected",
// "optionId": "…"}}`, or `{"outcome": {"outcome": "cancelled"}}`.
type permissionOutcome struct {
	Outcome struct {
		Outcome  string `json:"outcome"`
		OptionID string `json:"optionId"`
	} `json:"outcome"`
}

// permissionRequest is the stored line, decoded far enough to forward it and
// to answer it.
type permissionRequest struct {
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  map[string]any  `json:"params"`
	options []map[string]any
}

// forwardPermission carries one `session/request_permission` to the editor and
// posts the answer back to Fountain.
//
// This is the only place in either direction where a *request* travels up
// rather than a notification: sprite → Fountain → editor, and the answer back
// down the same two hops (#708). Everything about it is fail-closed, because
// the request exists precisely because someone decided this tool call should
// not run unattended:
//
//   - an editor that errors, disconnects, or dismisses the prompt denies the
//     call, immediately, with an option the agent itself offered;
//   - an option id the agent did not advertise is never sent — Fountain refuses
//     it anyway, and refusing here keeps the reason local to the editor;
//   - when the agent offered no rejection at all there is nothing honest to
//     send, so the request is left for the server's timeout, which denies it.
//
// The turn is blocked in the sprite while this runs, and the server's ask
// timeout (five minutes by default) bounds it from the other side.
func (a *Agent) forwardPermission(ctx context.Context, sess Session, line string) {
	req, ok := a.decodePermission(line)
	if !ok {
		return
	}

	requester, ok := a.requester()
	if !ok {
		// Nothing to ask. The web apps are peer clients of this same request,
		// so someone may still answer it; if nobody does the server denies it
		// on the timeout. Saying so in the log is the difference between a
		// bug and a turn that looks hung.
		a.log.Warn("a permission request arrived with no client attached to ask",
			"conversation", sess.ID, "request", requestID(req.ID))
		return
	}

	params := map[string]any{}
	for k, v := range req.Params {
		params[k] = v
	}
	// The stored line carries the *sprite's* session id and its own request id;
	// the editor knows this conversation by ours and must answer on an id from
	// our own space, so both are replaced. Same substitution forwardUpdate
	// makes, and for the same reason.
	params["sessionId"] = sess.ID
	a.movePermissionLocations(params)

	a.log.Debug("asking the editor for permission",
		"conversation", sess.ID, "request", requestID(req.ID), "options", len(req.options))

	raw, err := requester.Request(ctx, "session/request_permission", params)
	if err != nil {
		// A detached editor is distinguishable from nobody attached, and #708
		// asks that we say so rather than silently waiting out the timeout.
		a.log.Warn("the editor did not answer the permission request; denying it",
			"conversation", sess.ID, "err", err)
		a.denyPermission(ctx, sess, req)
		return
	}

	var outcome permissionOutcome
	if err := json.Unmarshal(raw, &outcome); err != nil {
		a.log.Warn("could not read the editor's permission answer; denying it",
			"conversation", sess.ID, "err", err)
		a.denyPermission(ctx, sess, req)
		return
	}

	if outcome.Outcome.Outcome != "selected" || outcome.Outcome.OptionID == "" {
		a.log.Info("the editor dismissed the permission request; denying it",
			"conversation", sess.ID, "outcome", outcome.Outcome.Outcome)
		a.denyPermission(ctx, sess, req)
		return
	}

	if !offered(req.options, outcome.Outcome.OptionID) {
		// The agent's own list is the whole vocabulary. An id outside it would
		// at best error server-side and at worst name something unrelated.
		a.log.Warn("the editor chose an option the agent never offered; denying it",
			"conversation", sess.ID, "option", outcome.Outcome.OptionID)
		a.denyPermission(ctx, sess, req)
		return
	}

	a.answerPermission(ctx, sess, req, outcome.Outcome.OptionID)
}

// denyPermission answers with a rejection the agent offered, and gives up
// rather than inventing one when it offered none.
func (a *Agent) denyPermission(ctx context.Context, sess Session, req permissionRequest) {
	option, ok := rejection(req.options)
	if !ok {
		a.log.Warn("the agent offered no way to refuse; leaving the request for the server timeout",
			"conversation", sess.ID, "request", requestID(req.ID))
		return
	}
	a.answerPermission(ctx, sess, req, option)
}

func (a *Agent) answerPermission(ctx context.Context, sess Session, req permissionRequest, optionID string) {
	err := a.api.AnswerPermission(ctx, sess.ID, requestID(req.ID), optionID)
	switch {
	case err == nil:
		a.log.Debug("answered a permission request",
			"conversation", sess.ID, "option", optionID)
	case IsAlreadyResolved(err):
		// Another attached client, the timeout, or the turn ending got there
		// first. #940 makes first-answer-wins the contract, so losing that race
		// is an ordinary outcome, not a failure.
		a.log.Info("the permission request was already resolved",
			"conversation", sess.ID, "request", requestID(req.ID))
	default:
		a.log.Error("could not deliver the permission answer",
			"conversation", sess.ID, "err", err)
	}
}

// decodePermission parses a stored line and reports whether it is a permission
// request this adapter should forward.
func (a *Agent) decodePermission(line string) (permissionRequest, bool) {
	var req permissionRequest
	if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &req); err != nil {
		return req, false
	}
	if req.Method != "session/request_permission" || len(req.ID) == 0 {
		return req, false
	}
	if req.Params == nil {
		req.Params = map[string]any{}
	}
	req.options = optionList(req.Params["options"])
	return req, true
}

// movePermissionLocations does for a permission request's tool call what
// moveSandboxLocations does for a tool_call update: the paths are the
// sandbox's, and an editor that opens them opens the wrong file.
func (a *Agent) movePermissionLocations(params map[string]any) {
	call, ok := params["toolCall"].(map[string]any)
	if !ok {
		return
	}
	locations, ok := call["locations"]
	if !ok || locations == nil {
		return
	}

	// Copy rather than mutate: the map came from the stored line, and the same
	// line is what the transcript renders.
	moved := map[string]any{}
	for k, v := range call {
		moved[k] = v
	}
	delete(moved, "locations")

	meta, ok := moved["_meta"].(map[string]any)
	if !ok {
		meta = map[string]any{}
	}
	meta[MetaSandboxLocations] = locations
	moved["_meta"] = meta
	params["toolCall"] = moved
}

func optionList(raw any) []map[string]any {
	list, ok := raw.([]any)
	if !ok {
		return nil
	}
	options := make([]map[string]any, 0, len(list))
	for _, entry := range list {
		if option, ok := entry.(map[string]any); ok {
			options = append(options, option)
		}
	}
	return options
}

func offered(options []map[string]any, optionID string) bool {
	for _, option := range options {
		if id, ok := option["optionId"].(string); ok && id == optionID {
			return true
		}
	}
	return false
}

// rejection returns the id of the first refusing option the agent offered.
// `reject_always` before `reject_once` would be a policy decision this adapter
// has no business making, so it takes them in the agent's own order.
func rejection(options []map[string]any) (string, bool) {
	for _, option := range options {
		kind, _ := option["kind"].(string)
		if !strings.HasPrefix(kind, "reject_") {
			continue
		}
		if id, ok := option["optionId"].(string); ok && id != "" {
			return id, true
		}
	}
	return "", false
}

// requestID is the id as the answer route takes it: the stored line's own,
// stringified, exactly as the server stringifies it.
func requestID(raw json.RawMessage) string {
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	return strings.TrimSpace(string(raw))
}
