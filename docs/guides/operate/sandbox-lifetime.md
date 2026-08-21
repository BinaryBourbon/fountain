# Change sandbox lifetimes

This guide shows you how to widen, narrow or disable the two bounds that
reclaim a sandbox, and what each one costs.

## The two bounds

They do different things, and the difference matters more than the numbers.

| Setting | Default | |
|---|---|---|
| `SANDBOX_IDLE_TIMEOUT_MINUTES` | `60` | No turn activity for this long and the sandbox is **suspended**. The sprite stays, scaled to zero, and the next prompt wakes it with the agent's memory intact |
| `SANDBOX_MAX_LIFETIME_HOURS` | `24` | Ceiling on a continuous run, from creation or the last wake. Crossing it **destroys** the sprite, the backstop for a conversation that never stops being busy |

Set either to `0` to disable it. A value that is not a non-negative integer
refuses to boot rather than quietly disabling the bound.

## Which one you can be aggressive with

Neither bound ends the conversation. It stays resumable either way.

The idle bound is free to be aggressive, because suspension loses nothing.

The max-lifetime ceiling is not. The runtime session lives on the destroyed
disk, so after a ceiling reclaim the next prompt provisions fresh and the agent
starts without its memory of the earlier turns. Expect users to restate context
after one.

Suspended sandboxes are never aged out. Their sprites persist at the provider
until the conversation is terminated or the account deleted.

## Not every provider can suspend

A provider that does not advertise the `:suspend` capability destroys on idle
rather than faking a park, because resuming with a fresh disk would be silent
loss of the agent's memory. See
[the sandbox contract](../../integrations/sandbox-contract.md).

So on such a provider, lowering the idle timeout is not free. It has the cost
of the ceiling.

## Verify it worked

The reaper logs one summary line per run, hourly at :07.

```bash
kubectl logs -n fountain -l app=fountain --since=2h | grep 'reaper:'
# reaper: released=0 parked=1 expired=0 destroyed=2 untracked=102 live=114
```

`parked` is the reaper suspending idle sandboxes, which is reversible
bookkeeping rather than a teardown.

## Related

- [About conversations](../../concepts/conversation.md), for what suspend and
  destroy mean to a user.
- [Conversation states](../../reference/conversation-states.md).
- [Configuration reference](../../configuration.md).
