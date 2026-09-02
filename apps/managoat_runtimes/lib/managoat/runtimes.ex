defmodule Managoat.Runtimes do
  @moduledoc """
  Behaviour every runtime (claude/codex/gemini/opencode) implements,
  plus a small dispatcher.

  How a coding agent CLI gets into a sandbox and comes up speaking the Agent
  Client Protocol: which adapter to install and at what version
  (`Managoat.Runtimes.ACP`), where its files go (`Managoat.Runtimes.Layout`),
  the instructions file (`Managoat.Runtimes.Instructions`), the skills tree
  (`Managoat.Runtimes.Skills`), the credential env vars (each runtime's
  `default_env/2`), and the per-runtime workarounds with the condition for
  deleting each (`Managoat.Runtimes.Quirks`). The protocol session itself is
  `Managoat.ACP.Peer`; this library is the **provisioning** half that a peer
  needs to have happened first.

  `build_command/5` has **no implementation left** — gemini was the last
  runtime to build a CLI argv for a turn, and that went when every runtime
  moved onto ACP — so the callback stays optional and a host's legacy spawn
  path is unreachable for any runtime `for_runtime/1` will resolve. It is kept
  rather than deleted because a fifth runtime that cannot speak ACP would
  need it, and because the turn machinery a host builds around it (log
  budget, exit handling) is shared and still exercised through
  `Managoat.Runtimes.Testing.FakeRuntime`.

  What varies between runtimes here falls into three kinds, and only the last
  needs code:

    * **Layout** — where files go. Perfectly regular (`<home>/<config_dir>/…`)
      and now stated once, in `Managoat.Runtimes.Layout`. `skills_root/0`,
      `skills_sh_agent/0`, the instructions path and every workspace directory
      are derived from that table rather than restated per module.
    * **Workarounds** — a defect each runtime carries, with a deletion
      condition. Registered in `Managoat.Runtimes.Quirks`, which names the
      function implementing each one and is guarded by a test, so a workaround
      cannot outlive its defect unnoticed.
    * **Credential delivery** — genuinely irreducible, and two shapes rather
      than four: an env var (claude, gemini, opencode) or a login exec that
      consumes the key on stdin (codex, whose CLI ignores the process env).
      See `default_env/2` and `prepare_sandbox/3`.
  """

  @type mode :: :run | :continue
  @type cmd :: {String.t(), [String.t()], keyword()}

  @typedoc """
  What a runtime reads from the agent it provisions for.

  A plain map, so the host's own record satisfies it whatever else it
  carries: an Ecto struct, a decoded JSON document, a literal in a test. The
  five keys are the whole surface the library reads, and each is optional
  because every reader treats a missing one as "none":

    * `model` — the canonical `provider/model_id` (`Managoat.Runtimes.Model`);
      `OpenCode.default_env/2` picks the credential from its prefix.
    * `mcp_servers` — the agent's MCP servers in Claude's own config shape
      (`%{name => %{"command" | "args" | "env" | "type" | "url" | "headers"}}`),
      read by `write_config/2` and `Managoat.Runtimes.ACP.mcp_servers/1`.
    * `system` and `name` — the instructions file
      (`Managoat.Runtimes.Instructions`).
    * `runtime` — `Managoat.Runtimes.ACP.enabled?/1` accepts the agent as well
      as the bare runtime string.
  """
  @type agent :: %{
          optional(:model) => String.t() | nil,
          optional(:mcp_servers) => map() | nil,
          optional(:system) => String.t() | nil,
          optional(:name) => String.t() | nil,
          optional(:runtime) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc """
  Build the argv (and any extra spawn opts like `:env`) for a single turn on
  the **legacy** spawn path. Only runtimes excluded from
  `Managoat.Runtimes.ACP.supported_runtimes/0` need this; for everything else
  the turn travels over ACP and argv says nothing about it.

  - `mode == :run` for the first turn
  - `mode == :continue` for subsequent turns
  - `runtime_session_id` is the runtime CLI's own session id used for resume
  """
  @callback build_command(
              agent :: agent(),
              prompt :: String.t(),
              mode :: mode(),
              runtime_session_id :: String.t() | nil,
              opts :: keyword()
            ) :: cmd()

  @doc """
  Default env vars for the runtime — typically the inference credential
  for the chosen provider (e.g. `ANTHROPIC_API_KEY`).

  `inference_credentials` is a map of `%{provider_atom => plaintext_string}`
  the host decrypts for the tenant at conversation start. The keys a runtime
  reads are `:anthropic_api_key`, `:claude_code_oauth_token`,
  `:openai_api_key` and `:gemini_api_key`; providers the user hasn't set are
  simply absent from the map.

  ## Why this cannot be a table

  Three things happen here that layout cannot express, and they are the
  reason this stays a callback rather than another column:

    * **Which provider.** claude, codex and gemini each have one. opencode is
      a front-end for all three, so the variable it needs is a function of
      `agent.model` — `Managoat.Runtimes.Model.provider/1` decides at
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
              agent :: agent(),
              inference_credentials :: %{atom() => String.t()}
            ) :: [{String.t(), String.t()}]

  @doc """
  Optionally write runtime-specific config files into the sprite at
  provision time (e.g. claude's `~/.claude.json` for MCP servers).
  No-op by default.
  """
  @callback write_config(handle :: Managoat.Sandbox.Handle.t(), agent :: agent() | nil) ::
              :ok | {:error, term()}

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
  `Managoat.Runtimes.Layout`; what is left here is the residue that has to be
  code.

  Runs after `Managoat.Runtimes.ACP.install/3` and after the host's whole
  provisioning pipeline, so it can assume the adapter is on PATH. Note the
  ordering costs something: if the host has already applied a network policy
  to the sandbox, opencode's `bun install` here needs the npm registry on the
  allowlist of any restricted one. It works today because the default is
  unrestricted.
  """
  @callback prepare_sandbox(
              handle :: Managoat.Sandbox.Handle.t(),
              agent :: agent() | nil,
              sprite_env :: [{String.t(), String.t()}]
            ) :: :ok | {:error, term()}

  @doc """
  Absolute path on the sprite where inline skills are written as
  `<skills_root>/<name>/SKILL.md`. Each runtime points this at whatever
  directory its CLI scans for skills.

  Answered from `Managoat.Runtimes.Layout` by every implementation — it stays
  a callback because `Managoat.Runtimes.Skills` reaches it through the module,
  not because any runtime has ever needed to depart from the table.
  """
  @callback skills_root() :: String.t()

  @doc """
  Identifier passed to `npx skills add ... --agent <id>` when installing
  a github-source skill. The skills.sh CLI uses this to choose the
  on-disk layout for the target runtime (claude-code, codex, gemini-cli,
  opencode). Also from `Managoat.Runtimes.Layout`.
  """
  @callback skills_sh_agent() :: String.t()

  @optional_callbacks build_command: 5, default_env: 2, write_config: 2, prepare_sandbox: 3

  @runtime_modules %{
    "claude" => Managoat.Runtimes.Claude,
    "codex" => Managoat.Runtimes.Codex,
    "gemini" => Managoat.Runtimes.Gemini,
    "opencode" => Managoat.Runtimes.OpenCode
  }

  @doc "Look up the runtime module for an agent's runtime string."
  def for_runtime(name) when is_binary(name) do
    case Map.fetch(@runtime_modules, name) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, "unsupported runtime: #{name}"}
    end
  end
end
