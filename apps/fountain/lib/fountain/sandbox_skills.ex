defmodule Fountain.SandboxSkills do
  @moduledoc """
  The skills every Fountain sandbox gets, and the call that mounts them with
  the agent's own.

  The mechanism — inline `SKILL.md` writes under the runtime's skills root,
  skills.sh installs for github sources, the shell allow-list — is
  `Managoat.Runtimes.Skills`. What is Fountain's is the content: the bundled
  skills under `priv/sprite_skills/`, prepended to every agent's list so the
  per-conversation callback API and the team set-up Q&A are discoverable
  inside the sprite.
  """

  require Logger

  @bundle_root "sprite_skills"
  @fountain_skill_name "fountain"
  # Every sandbox gets these, in this order: the API skill, then the team
  # set-up Q&A (#851) — so a first teammate can answer "/create-team".
  @bundled_skills [@fountain_skill_name, "create-team"]

  @doc """
  Mount `skills` (a list of inline/github maps, the agent's `skills` field)
  on the sandbox behind `handle` for the named runtime. The bundled skills
  are always prepended.

  A runtime **string** is resolved here, through `Fountain.RuntimeDispatch`
  rather than through the library's own dispatcher (#1634).
  `Managoat.Runtimes.Skills` resolves a string through
  `Managoat.Runtimes.for_runtime/1`, which is a closed map of the four
  packaged runtimes and knows neither `acp` nor the deployed fixture — so
  passing the string straight through returned
  `{:error, "unsupported runtime: acp"}` and an acp sandbox came up with no
  skills at all and nothing said so.

  Failure is logged rather than raised, and returned for a caller that wants
  it. A missing skill is a degraded agent, not a broken one, which is the
  trade `Managoat.Runtimes.Skills` already makes for one skill that will not
  install; this extends it to a runtime that cannot be resolved.
  """
  @spec mount(Managoat.Sandbox.Handle.t(), String.t() | module(), [map()] | nil) ::
          :ok | {:error, String.t()}
  def mount(handle, runtime, skills) when is_binary(runtime) do
    # `for_agent/1` takes the agent because the deployed fixture is scoped to
    # one account. Skills are refused on a fixture agent by its own changeset,
    # so a nil user here resolves to the refusal, which is the right answer.
    case Fountain.RuntimeDispatch.for_agent(%{runtime: runtime, user_id: nil}) do
      {:ok, module} ->
        mount(handle, module, skills)

      {:error, reason} ->
        Logger.warning("skills not mounted for runtime #{runtime}: #{reason}")
        {:error, reason}
    end
  end

  def mount(handle, runtime_module, skills) when is_atom(runtime_module) do
    Managoat.Runtimes.Skills.install(handle, bundled() ++ (skills || []), runtime: runtime_module)
  end

  @doc """
  The bundled skills as inline entries, in the order they are mounted.
  """
  @spec bundled() :: [%{String.t() => String.t()}]
  # sobelow_skip ["Traversal.FileModule"] — fixed path assembled from
  # priv_dir and a module attribute; no user input.
  def bundled do
    Enum.map(@bundled_skills, fn name ->
      %{"name" => name, "content" => File.read!(Path.join([priv_dir(), name, "SKILL.md"]))}
    end)
  end

  defp priv_dir do
    Path.join(:code.priv_dir(:fountain) |> to_string(), @bundle_root)
  end
end
