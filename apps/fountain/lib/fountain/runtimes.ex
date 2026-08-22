defmodule Fountain.Runtimes do
  @moduledoc """
  Behaviour every runtime (claude/codex/gemini/opencode) implements,
  plus a small dispatcher.

  This is the **provisioning** layer ADR 0014 deliberately kept: credentials,
  skills layout, sandbox bootstrap. Turn I/O is ACP (`Fountain.Runtimes.ACP`)
  for every supported runtime. `build_command/5` has **no implementation left**
  — gemini was the last one and #941 deleted it — so the callback stays
  optional and the legacy spawn path in `ConversationServer` is unreachable for
  any runtime `for_runtime/1` will resolve. Both are kept rather than deleted
  because a fifth runtime that cannot speak ACP would need them, and because
  the turn machinery around them (log budget, exit handling) is shared and
  still exercised through `Fountain.Test.FakeRuntime`.

  What varies between runtimes here falls into three kinds, and only the last
  needs code:

    * **Layout** — where files go. Perfectly regular (`<home>/<config_dir>/…`)
      and now stated once, in `Fountain.Runtimes.Layout`. `skills_root/0`,
      `skills_sh_agent/0`, the instructions path and every workspace directory
      are derived from that table rather than restated per module.
    * **Workarounds** — an upstream defect each runtime carries, with a
      deletion condition: claude's MCP servers going in as files because the
      ACP session-scoped channel is dropped on the floor
      (`claude-agent-acp#883`), gemini's session store consolidation
      (`gemini-cli#28775`), opencode not being on the base image, and
      `HOME=/tmp` for the two runtimes that trip the sprite's rename ACL.
    * **Credential delivery** — genuinely irreducible, and two shapes rather
      than four: an env var (claude, gemini, opencode) or a login exec that
      consumes the key on stdin (codex, whose CLI ignores the process env).
      See `default_env/2` and `prepare_sandbox/3`.
  """

  alias Fountain.Agents.Agent

  @type mode :: :run | :continue
  @type cmd :: {String.t(), [String.t()], keyword()}

  @doc """
  Build the argv (and any extra spawn opts like `:env`) for a single turn on
  the **legacy** spawn path. Only runtimes excluded from
  `Fountain.Runtimes.ACP.supported_runtimes/0` need this; for everything else
  the turn travels over ACP and argv says nothing about it.

  - `mode == :run` for the first turn
  - `mode == :continue` for subsequent turns
  - `runtime_session_id` is the runtime CLI's own session id used for resume
  """
  @callback build_command(
              agent :: %Agent{},
              prompt :: String.t(),
              mode :: mode(),
              runtime_session_id :: String.t() | nil,
              opts :: keyword()
            ) :: cmd()

  @doc """
  Default env vars for the runtime — typically the inference credential
  for the chosen provider (e.g. `ANTHROPIC_API_KEY`).

  `inference_credentials` is a map of `%{provider_atom => plaintext_string}`
  decrypted from the user's `inference_credentials` row at conversation
  start (see `Fountain.InferenceCredentials.decrypted_for_user/2`).
  Providers the user hasn't set are simply absent from the map.

  ## Why this cannot be a table

  Three things happen here that layout cannot express, and they are the
  reason this stays a callback rather than another column:

    * **Which provider.** claude, codex and gemini each have one. opencode is
      a front-end for all three, so the variable it needs is a function of
      `agent.model` — `Fountain.Runtimes.Model.provider/1` decides at
      provision time.
    * **Which credential, for one provider.** claude takes either a
      `CLAUDE_CODE_OAUTH_TOKEN` (bills a Claude.ai subscription) or an
      `ANTHROPIC_API_KEY` (metered), never both — exporting both has picked
      the wrong one depending on CLI version. The precedence, and the
      mid-conversation fall back to the API key when an org refuses the OAuth
      token (#655), are provider policy with no analogue on the others.
    * **Whether an env var works at all.** codex 0.118+ does not read
      `OPENAI_API_KEY` at exec time. It reads `~/.codex/auth.json`, which only
      `codex login --with-api-key` writes, so its credential is delivered by
      `prepare_sandbox/3` instead — see there.

  So the shape is two-of-four, not four-of-four: an env var, or a login exec.
  Worth restating whenever a fifth runtime arrives, because "just add a column
  for the variable name" is right up until it is codex.
  """
  @callback default_env(
              agent :: %Agent{},
              inference_credentials :: %{atom() => String.t()}
            ) :: [{String.t(), String.t()}]

  @doc """
  Optionally write runtime-specific config files into the sprite at
  provision time (e.g. claude's `~/.claude.json` for MCP servers).
  No-op by default.
  """
  @callback write_config(handle :: Fountain.Sandbox.Handle.t(), agent :: %Agent{} | nil) :: :ok

  @doc """
  Optionally run any sprite-side bootstrap that has to happen *before*
  the first turn — e.g. codex needs `codex login --with-api-key` to
  persist credentials into `~/.codex/auth.json` since it doesn't read
  `OPENAI_API_KEY` from the live process env.

  Receives the same `sprite_env` pairs the spawn will use. Implementers
  pull whichever keys they need out of that list. No-op by default.

  ## This is the escape hatch, and it should stay one

  Three runtimes implement it and each does something genuinely imperative —
  a login that consumes a key on stdin, a `bun install`, a `git init`. None
  of those is expressible as data, and an abstraction that swallowed them
  would cost more than the duplication it removed. What *was* data (where the
  workspace lives, what HOME is) has already moved to
  `Fountain.Runtimes.Layout`; what is left here is the residue that has to be
  code.

  Runs after `Fountain.Runtimes.ACP.install/3` and after the whole
  provisioning pipeline, so it can assume the adapter is on PATH. Note the
  ordering costs something: `Provisioning.apply_network_policy/3` has already
  run, so opencode's `bun install` here needs the npm registry on the
  allowlist of any `limited` environment. It works today because the default
  is `unrestricted`.
  """
  @callback prepare_sandbox(
              handle :: Fountain.Sandbox.Handle.t(),
              agent :: %Agent{} | nil,
              sprite_env :: [{String.t(), String.t()}]
            ) :: :ok | {:error, term()}

  @doc """
  Absolute path on the sprite where inline skills are written as
  `<skills_root>/<name>/SKILL.md`. Each runtime points this at whatever
  directory its CLI scans for skills.

  Answered from `Fountain.Runtimes.Layout` by every implementation — it stays
  a callback because `Fountain.SandboxSkills` reaches it through the module,
  not because any runtime has ever needed to depart from the table.
  """
  @callback skills_root() :: String.t()

  @doc """
  Identifier passed to `npx skills add ... --agent <id>` when installing
  a github-source skill. The skills.sh CLI uses this to choose the
  on-disk layout for the target runtime (claude-code, codex, gemini-cli,
  opencode). Also from `Fountain.Runtimes.Layout`.
  """
  @callback skills_sh_agent() :: String.t()

  @optional_callbacks build_command: 5, default_env: 2, write_config: 2, prepare_sandbox: 3

  @runtime_modules %{
    "claude" => Fountain.Runtimes.Claude,
    "codex" => Fountain.Runtimes.Codex,
    "gemini" => Fountain.Runtimes.Gemini,
    "opencode" => Fountain.Runtimes.OpenCode
  }

  @doc "Look up the runtime module for an agent's runtime string."
  def for_runtime(name) when is_binary(name) do
    case Map.fetch(@runtime_modules, name) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, "unsupported runtime: #{name}"}
    end
  end
end
