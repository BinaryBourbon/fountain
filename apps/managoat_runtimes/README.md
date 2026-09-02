# Managoat.Runtimes

How a coding agent CLI — claude, codex, gemini or opencode — gets into a
sandbox and comes up speaking the [Agent Client Protocol](https://agentclientprotocol.com).
The protocol session itself is [`managoat_acp`](https://hex.pm/packages/managoat_acp);
the sandbox it runs in is [`managoat_sandbox`](https://hex.pm/packages/managoat_sandbox).
This package is what has to have happened on the sandbox *before* a peer can
open a session: which adapter to install and at what version, where the
runtime keeps its files, the instructions file that carries the agent's
system prompt, the credential env vars, the skills tree, and the per-runtime
workarounds with the condition for deleting each one.

```elixir
alias Managoat.Runtimes
alias Managoat.Runtimes.{ACP, Instructions, Skills}

{:ok, handle} = Managoat.Sandbox.create("my-agent", provider: :sprites)
{:ok, runtime} = Runtimes.for_runtime("claude")

agent = %{
  name: "reviewer",
  model: "anthropic/claude-sonnet-4-6",
  system: "You review pull requests. Be brief.",
  mcp_servers: %{"gh" => %{"command" => "gh-mcp", "env" => %{"GITHUB_TOKEN" => token}}}
}

# 1. The credential env for this runtime, from the credentials the host holds.
env = runtime.default_env(agent, %{anthropic_api_key: key})

# 2. Files: the runtime's own config (claude's .mcp.json), the system prompt,
#    the skills.
:ok = runtime.write_config(handle, agent)
:ok = Instructions.write(handle, "claude", agent)
:ok = Skills.install(handle, [%{"name" => "house-style", "content" => skill_md}], runtime: "claude")

# 3. The ACP adapter, pinned, then whatever bootstrap the runtime needs.
:ok = ACP.install(handle, "claude", env)
:ok = runtime.prepare_sandbox(handle, agent, env)

# 4. Spawn it and hand the process to Managoat.ACP.Peer.
{bin, args} = ACP.command("claude")
{:ok, command} = Managoat.Sandbox.spawn(handle, bin, args, env: env, dir: ACP.cwd("claude"), stdin: true)

{:ok, peer} =
  Managoat.ACP.Peer.start(
    owner: self(),
    writer: &Managoat.Sandbox.write_stdin(command, &1),
    ref: command.ref,
    prompt: "review PR 42",
    mode: :run,
    session_id: nil,
    cwd: ACP.cwd("claude"),
    mcp_servers: ACP.mcp_servers(agent),
    model: Managoat.Runtimes.Model.acp_model("claude", agent.model)
  )
```

## The pieces

| Module | Role |
|---|---|
| `Managoat.Runtimes` | The behaviour (`default_env/2`, `write_config/2`, `prepare_sandbox/3`, `skills_root/0`, `skills_sh_agent/0`, and an optional `build_command/5` for a runtime that cannot speak ACP) and `for_runtime/1`, the dispatcher from a runtime name to its module. The agent is read as a plain map, `t:Managoat.Runtimes.agent/0`, so the host's own record satisfies it. |
| `Managoat.Runtimes.ACP` | The adapter table: which package and **pinned** version reach ACP for each runtime (`@agentclientprotocol/claude-agent-acp`, `@agentclientprotocol/codex-acp`; gemini and opencode are native), `install/3`, `command/1`, `cwd/1`, `concurrency/1` (how many turns one sandbox takes for the runtime), `asks_permission?/1` (measured, not assumed), `mcp_servers/1` in the shape `session/new` takes, and `initialize_params/1`. |
| `Managoat.Runtimes.{Claude, Codex, Gemini, OpenCode}` | One module per runtime: credentials in, env and files out. Two credential shapes, not four: an env var, or a login exec that consumes the key on stdin (codex). |
| `Managoat.Runtimes.Layout` | The one table every path derives from: `<home>/<config_dir>/<leaf>` per runtime. gemini and opencode run with `HOME=/tmp`, and deriving the HOME export and the file paths from the same row is what keeps a system prompt from being written where the CLI never looks. |
| `Managoat.Runtimes.Instructions` | The user-level instructions file each runtime reads at session start (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`), which is where the agent's system prompt is delivered. |
| `Managoat.Runtimes.Skills` | Inline `SKILL.md` writes under the runtime's skills root and skills.sh installs for github sources, behind a shell allow-list. The list is the host's to assemble. |
| `Managoat.Runtimes.Model` | The `provider/model_id` parser: which provider a runtime reaches, the bare id a single-provider CLI wants, the canonical id opencode wants. Which models to *suggest* is the host's product data and is not here. |
| `Managoat.Runtimes.Quirks` | Every workaround carried on a runtime's behalf, as a registry: the defect, the upstream issue, how to re-probe it, what to delete when it is fixed, and the function that implements it (a test asserts that function still exists). |
| `Managoat.Runtimes.Gemini.SessionStore` | The largest of those workarounds: gemini's own session store erases a session in the act of loading it, so this consolidates the store after every turn. Goes when google-gemini/gemini-cli#28775 lands. |
| `Managoat.Runtimes.Testing.FakeRuntime` | A runtime for tests that reports every callback to an observer, plus two that fail on purpose. Ships in `lib/` so a host's tests can drive their turn machinery without a CLI. |

## What the host still does

This package writes files into a sandbox and tells you what to spawn. It
does not spawn, does not hold the protocol session, and does not know the
tenant. The host:

- decrypts the tenant's inference credentials and passes them to
  `default_env/2` as `%{anthropic_api_key: ..., openai_api_key: ...,
  gemini_api_key: ..., claude_code_oauth_token: ...}`;
- decides the skills list (Fountain prepends its own API skill to the
  agent's);
- reads its own configuration for how long a held permission waits for a
  human, and passes it to `Managoat.ACP.Permissions.ask_timeout_ms/1`;
- applies any network policy to the sandbox, and calls `ACP.install/3` and
  `prepare_sandbox/3` *after* it, with the npm registry allowed if the policy
  restricts egress;
- calls `Gemini.SessionStore.consolidate/2` at the end of every gemini turn.

## The adapter is pinned, and that is load-bearing

An unpinned adapter can stop advertising `sessionCapabilities.resume` in a
point release and silently downgrade every conversation to a full history
replay per turn. So the versions in `Managoat.Runtimes.ACP` are exact, the
install is idempotent on that exact version (an image carrying a different
one is corrected, not accepted), and a pin moves in a commit that says why.

## Licence

Apache-2.0. Extracted from [Fountain](https://github.com/BinaryBourbon/fountain)
under its decision record 0037; the issue numbers in the source are that
repository's.
