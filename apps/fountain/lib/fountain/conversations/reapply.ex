defmodule Fountain.Conversations.Reapply do
  @moduledoc """
  Re-selecting a conversation's Agent, Environment and Vault (#1565).

  A reapply keeps the conversation, its id, its transcript **and its machine**.
  What it changes is what the machine is configured with, on the machine that
  is already there. The disk survives, so an agent's cloned repositories,
  uncommitted work and build output are still where it left them.

  ## What updates in place, and what does not

  Most of a launch configuration is either process environment or a file, and
  both of those can be rewritten under a running sandbox. The reattach path
  has always done exactly this (`ConversationServer.do_reattach/6` rewrites
  `.mcp.json`, the `.env` file and the instructions on every wake), so this is
  the established mechanism rather than a new one.

  | Change | How it lands | Rebuild |
  |---|---|---|
  | Environment variables, Vault values | Respawn the runtime with fresh env | no |
  | System prompt, skills, MCP servers | Rewrite the files | no |
  | Model, permission policy | Per-turn arguments | no |
  | Runtime (claude to codex, say) | Adapter install | **yes** |
  | Packages, repositories, setup script | Install, clone, run | **yes** |
  | Network policy | Egress rules, written once at provision | **yes** |

  The rebuild rows are not stubbornness. The ACP adapter is an npm install
  that provisioning deliberately does *before* the network policy is applied
  (`Provisioning.prepare_acp_adapter/3`), so installing a different one later
  fails in a way that reads as a protocol bug. And `git clone` refuses a
  checkout that already exists while a setup script that starts services fails
  on its second run, which is the same reason
  `Provisioning.discard_interrupted_attempt/3` exists.

  The network policy is the cautious one. `Egress.apply_policy/4` runs once,
  at provision, and nothing has ever re-run it against a live machine. Rather
  than assume it is idempotent and find out in production, a networking change
  is refused. Relaxing that is a one-line change to `fingerprint/1`, once
  somebody has shown the re-application is safe.

  One gap is worth naming. A skill whose source is a GitHub repository is a
  clone, and by the time a reapply runs the machine's network policy is
  already in force. Bundled skills are file writes and always land; a remote
  one may not, under a restrictive policy.

  So a reapply that needs either of those is refused, and says which field
  forced it. Start a new conversation for that, or rebuild the machine under
  the conversation with `DELETE /api/sandboxes/:id` (#1071).

  ## The cotenant rule

  Skills, the instructions file and `.mcp.json` sit at per-sandbox paths
  (`Managoat.Runtimes.Layout`), not per-conversation ones, so rewriting them
  rewrites them for every conversation on that machine. Sharing only happens
  on a persistent home or an explicit `sandbox_id` attach, and
  `Conversations.check_attachable/4` already pins every conversation on a
  machine to one `(user, agent, environment, vault)`. A conversation that has
  the machine to itself can therefore be reconfigured freely; one that shares
  it may only be reapplied to the selection its cotenants already have, which
  is what a refresh is.
  """

  alias Fountain.Conversations.Sandbox
  alias Fountain.Environments.Environment

  import Ecto.Query
  alias Fountain.{Conversations, Repo}

  @doc false
  def transaction(sandbox_id, fun) do
    Repo.transaction(fn ->
      if sandbox_id do
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(sandbox_id)])
      end

      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc false
  def update_identity(%{sandbox_id: nil}, _agent, _env_id, _vault_id), do: :ok

  def update_identity(conv, agent, env_id, vault_id) do
    # ownership: conv came from the tenant-scoped API fetch or its own server.
    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    # Older disks have no manifest. Seed reconciliation from the configuration
    # recorded before this reapply, not the newly selected agent's skills.
    previous = sandbox.applied_skills || previous_skills(conv)

    case Conversations.update_sandbox(sandbox, %{
           agent_id: agent.id,
           environment_id: env_id || agent.environment_id,
           vault_id: vault_id,
           applied_skills: previous
         }) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp previous_skills(%{agent_version_id: nil}), do: []

  defp previous_skills(conv) do
    # The conversation's own version; ownership was checked at the API door.
    case Repo.one(
           from v in Fountain.Agents.AgentVersion,
             where: v.id == ^conv.agent_version_id and v.user_id == ^conv.user_id
         ) do
      nil -> []
      version -> version.config["skills"] || []
    end
  end

  @doc false
  def mount_skills(handle, conv, agent) do
    # ownership: conv came from the tenant-scoped API fetch or its own server.
    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    skills = (agent && agent.skills) || []
    runtime = conv.runtime || (agent && agent.runtime) || "claude"

    with :ok <-
           Fountain.SandboxSkills.reconcile(
             handle,
             runtime,
             skills,
             sandbox.applied_skills || previous_skills(conv)
           ),
         {:ok, _} <- Conversations.update_sandbox(sandbox, %{applied_skills: skills}) do
      :ok
    end
  end

  @doc false
  def reply({:noreply, state}), do: {:reply, :ok, state}
  def reply({:noreply, state, continuation}), do: {:reply, :ok, state, continuation}

  @typedoc "Why a selection cannot be applied to the machine that is already there."
  @type blocker ::
          :runtime
          | :packages
          | :repositories
          | :setup_script
          | :networking
          | :environment
          | :shared_sandbox

  @doc """
  The digest of the Environment fields that provisioning turns into disk
  state. `nil` for no environment, which is itself a stable value to compare.

  Only the fields that shape the disk or the machine's network go in.
  Variables and the checkpoint are deliberately absent: a variable reaches a
  running machine on its next spawn, and the checkpoint only ever applies to a
  machine being built.
  """
  @spec fingerprint(Environment.t() | nil) :: String.t()
  def fingerprint(nil), do: "none"

  def fingerprint(%Environment{} = env) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {env.packages, env.repositories, env.setup_script, env.networking_type,
         env.networking_config}
      )
    )
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  @doc """
  Whether the machine `sandbox` already is can be reconfigured into the
  requested selection, or the first reason it cannot.

  `built_with` is the Environment the sandbox records, used only when the row
  predates `build_fingerprint` and so cannot answer for itself.
  """
  @spec check(Sandbox.t() | nil, keyword()) :: :ok | {:error, {:rebuild_required, blocker()}}
  def check(nil, _opts), do: :ok

  def check(%Sandbox{} = sandbox, opts) do
    current_runtime = Keyword.fetch!(opts, :current_runtime)
    target_runtime = Keyword.fetch!(opts, :target_runtime)
    target_env = Keyword.fetch!(opts, :target_environment)
    built_with = Keyword.get(opts, :built_with)

    cond do
      target_runtime != current_runtime ->
        {:error, {:rebuild_required, :runtime}}

      built_fingerprint(sandbox, built_with) == fingerprint(target_env) ->
        :ok

      true ->
        {:error, {:rebuild_required, build_field(built_with, target_env)}}
    end
  end

  # A row written since #1565 answers for itself. An older one cannot, so the
  # environment it records stands in: that catches a selection pointing at a
  # different environment, and misses only an environment edited before this
  # column existed.
  defp built_fingerprint(%Sandbox{build_fingerprint: fp}, _built_with) when is_binary(fp), do: fp
  defp built_fingerprint(_sandbox, built_with), do: fingerprint(built_with)

  # Which field to name in the refusal. Falls back to `:environment` when the
  # machine cannot say what it was built from and only the identity differs.
  defp build_field(%Environment{} = was, %Environment{} = now) do
    cond do
      was.packages != now.packages -> :packages
      was.repositories != now.repositories -> :repositories
      was.setup_script != now.setup_script -> :setup_script
      was.networking_type != now.networking_type -> :networking
      was.networking_config != now.networking_config -> :networking
      true -> :environment
    end
  end

  defp build_field(_was, _now), do: :environment

  @doc """
  A sentence naming what forced a rebuild, for the API error and the log.
  """
  @spec explain(blocker()) :: String.t()
  def explain(:runtime),
    do:
      "the selected agent runs a different runtime, and the ACP adapter is installed " <>
        "before the network policy that would now block installing another"

  def explain(:packages), do: "the selected environment installs different packages"
  def explain(:repositories), do: "the selected environment clones different repositories"
  def explain(:setup_script), do: "the selected environment runs a different setup script"

  def explain(:networking),
    do:
      "the selected environment applies a different network policy, and the egress rules " <>
        "are written once, when the machine is built"

  def explain(:environment),
    do: "the selected environment builds the machine differently"

  def explain(:shared_sandbox),
    do:
      "other conversations share this machine, and its skills, instructions and MCP " <>
        "configuration are per-machine rather than per-conversation"
end
