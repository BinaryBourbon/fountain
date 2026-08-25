# Feature status

Most of Fountain is on for every account. Two features are not. This page
lists them, says who has them on the hosted platform, and says how to get
them.

A note with the same title as the row sits at the top of each page that
describes one of these features.

| Feature | Status | On the hosted platform | On your own instance |
|---|---|---|---|
| [Teammate email and phone](../catalog/mcp-servers/fountain-comms.md) | Alpha | Off by default. Behind the `team_comms` flag. [Ask us](../api.md#support) to turn it on for your account. | Set the AgentMail and AgentPhone keys, and add `team_comms` to `FEATURE_FLAGS_ON`. Read the [configuration reference](../configuration.md#teammate-email-and-phone). |
| [Brokered credentials](../concepts/secrets.md#bindings-when-the-broker-is-on) | Limited access | Off by default. We enrol an account by hand. [Ask us](../api.md#support) to enrol yours. | Set `BROKER_URL` and its siblings, and list the user ids in `BROKER_TENANTS`. Read the [configuration reference](../configuration.md). |

## What each status means

**Alpha.** The feature works end to end, and we have not yet decided its final
shape. Its API and its tools can change between releases without an upgrade
note. Fountain refuses a call to it with a `404` when the flag is off.

**Limited access.** The feature works, and it changes what a sandbox can
reach. We turn it on for one account at a time, and we watch the first
conversations with you. Without it, a secret enters the sandbox in the clear,
and the pages and routes that manage bindings are absent.

## Where to go next

- [Where a secret comes from](../concepts/secrets.md), for what the broker
  changes.
- [fountain-comms](../catalog/mcp-servers/fountain-comms.md), for the tools a
  contact adds.
