# Change sandbox lifetimes

This guide shows you how to widen, narrow or stop the two bounds that reclaim
a sandbox. It also says what each one costs.

## The two bounds

They do different things, and that difference matters more than the numbers
do.

| Setting | Default | |
|---|---|---|
| `SANDBOX_IDLE_TIMEOUT_MINUTES` | `60` | No turn activity for this long **suspends** the sandbox. The sprite stays, scaled to zero. The next prompt wakes it, and the agent's memory is intact. |
| `SANDBOX_MAX_LIFETIME_HOURS` | `24` | A ceiling on one continuous run, from creation or from the last wake. To cross it **destroys** the sprite. It is the backstop for a conversation that never stops. |

Set either one to `0` to stop it. A value that is not a non-negative integer
refuses to boot, and it does not quietly turn the bound off.

## Which one you can be aggressive with

Neither bound ends the conversation. It stays resumable either way.

You can be aggressive with the idle bound, because a suspend loses nothing.

You cannot be aggressive with the max-lifetime ceiling. The runtime session
lives on the disk that the ceiling destroys. After a ceiling reclaim, the next
prompt provisions a fresh sandbox, and the agent starts with no memory of the
earlier turns. Expect a user to state their context again after one.

Fountain never ages a suspended sandbox out. Its sprite stays at the provider
until you terminate the conversation, or until somebody deletes the account.

## Not every provider can suspend

A provider that does not advertise the `:suspend` capability destroys on idle.
It does not fake a park, because a resume with a fresh disk would lose the
agent's memory without a sound. Read
[the sandbox contract](../../integrations/sandbox-contract.md).

So on such a provider, a lower idle timeout is not free. It costs what the
ceiling costs.

## Verify it worked

The reaper logs one summary line for each run, each hour at :07.

```bash
kubectl logs -n fountain -l app=fountain --since=2h | grep 'reaper:'
# reaper: released=0 parked=1 expired=0 destroyed=2 untracked=102 live=114
```

`parked` counts the idle sandboxes the reaper suspended. The reaper can undo
that, and it is not a teardown.

## Related

- [About conversations](../../concepts/conversation.md), for what suspend and
  destroy mean to a user.
- [Conversation states](../../reference/conversation-states.md).
- [Configuration reference](../../configuration.md).
