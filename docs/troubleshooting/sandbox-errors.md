# Sandbox errors

This guide shows you how to read a provisioning failure, and what the retries
have already tried on your behalf.

The examples below are the Sprites path, which is the default. The shape is the
same on other providers, because every adapter normalizes provider errors into
one taxonomy. See
[the sandbox contract](../integrations/sandbox-contract.md).

## What the retries already cover

Transient failures on the provisioning path (5xx, 429, timeouts) are tried up
to three times, meaning two retries, with exponential backoff. Each call is
bounded by `SPRITES_TIMEOUT_MS`, default 30s.

You only see a failure after that has been exhausted.

## What a 4xx means

These are deliberately **not** retried.

- **401 or 403.** The provider token is invalid, revoked, or missing. Check
  this first, because it fails every conversation while everything else looks
  healthy.
- **409 on create.** Already handled. The existing sandbox is adopted, so this
  is not an error you will see.

## During a provider outage

New conversations and wakes fail. A fresh provision marks the conversation
`failed`, and a wake leaves it resumable for later.

Sign-in, dashboards, configuration and past logs keep serving.

The readiness probe deliberately excludes the sandbox provider, because a third
party's uptime does not belong on the serving path. Do not expect pods to go
NotReady over it.

If you scrape metrics, provisioning failures show as
`fountain_stage_count{stage="provision", status="failed"}`, and completions as
`status="done"`.

## Quota, not outage

A user at their concurrent-sandbox quota, default 5, sees provisioning fail
while the provider is perfectly healthy. Crashed provisions leave rows that
count until the reaper releases them, hourly at :07. See
[A conversation is stuck or failed](conversation-stuck-or-failed.md).

## Related

- [A conversation is stuck or failed](conversation-stuck-or-failed.md).
- [The sandbox contract](../integrations/sandbox-contract.md), for the shared
  error taxonomy.
- [Wire up observability](../guides/operate/observability.md), for the
  provisioning-failure alert.
