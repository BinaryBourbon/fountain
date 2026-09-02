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

  @bundle_root "sprite_skills"
  @fountain_skill_name "fountain"
  # Every sandbox gets these, in this order: the API skill, then the team
  # set-up Q&A (#851) — so a first teammate can answer "/create-team".
  @bundled_skills [@fountain_skill_name, "create-team"]

  @doc """
  Mount `skills` (a list of inline/github maps, the agent's `skills` field)
  on the sandbox behind `handle` for the named runtime. The bundled skills
  are always prepended.
  """
  @spec mount(Managoat.Sandbox.Handle.t(), String.t() | module(), [map()] | nil) ::
          :ok | {:error, String.t()}
  def mount(handle, runtime, skills) do
    Managoat.Runtimes.Skills.install(handle, bundled() ++ (skills || []), runtime: runtime)
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
