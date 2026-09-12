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
  # Written at the skills root: which directories each Fountain-managed skill
  # put there, so a later reconciliation knows what it owns.
  @manifest_name ".fountain-managed-skills"
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
    reconcile(handle, runtime_module, skills, [])
  end

  @doc """
  Replace the Fountain-managed skills on a machine, leaving everything else
  under the skills root alone (#1565).

  Installing is not enough once a conversation can be reapplied. A skill the
  agent no longer names is still on the disk, and the runtime still reads it,
  so removing one from an agent would change nothing until the machine was
  rebuilt. Reconciling deletes what Fountain put there and is no longer
  selected, and only that.

  Three things make "only that" true:

  - **A manifest, written at the skills root.** It maps each selected skill
    to the directory names its install produced, so a later pass knows what
    it owns. A GitHub install without a `--skill` name decides its own
    directory names, which is why the manifest records what appeared rather
    than what was asked for.
  - **`previous`, for disks written before the manifest existed.** The
    conversation's recorded Agent version names the skills that were
    installed, and the skills.sh source lock names the directories an unnamed
    GitHub install produced. Anything neither can account for is left where
    it is: an entry with no ownership record is somebody else's.
  - **Only direct children of the skills root are ever removed**, each one
    matched against a conservative name pattern. Neither a forged manifest
    nor a legacy skill name can turn reconciliation into a delete somewhere
    else on the disk.

  A remote skill that is still selected keeps its directory when its
  reinstall fails, which is what an offline machine under a restrictive
  network policy looks like: the copy on the disk is the working one.
  """
  @spec reconcile(Managoat.Sandbox.Handle.t(), String.t() | module(), [map()] | nil, [map()]) ::
          :ok | {:error, term()}
  def reconcile(handle, runtime, skills, previous) when is_binary(runtime) do
    case Fountain.RuntimeDispatch.for_agent(%{runtime: runtime, user_id: nil}) do
      {:ok, module} ->
        reconcile(handle, module, skills, previous)

      {:error, reason} ->
        Logger.warning("skills not reconciled for runtime #{runtime}: #{reason}")
        {:error, reason}
    end
  end

  def reconcile(handle, runtime_module, skills, previous) when is_atom(runtime_module) do
    root = runtime_module.skills_root()
    manifest = Path.join(root, @manifest_name)
    selected = bundled() ++ (skills || [])

    with {:ok, raw} <-
           run(
             handle,
             "if [ -f #{quote_shell(manifest)} ]; then cat -- #{quote_shell(manifest)}; fi"
           ),
         {:ok, legacy} <- legacy_manifest(handle, previous),
         managed = Map.merge(legacy, decode_manifest(raw)),
         obsolete = obsolete_names(managed, selected),
         {:ok, _} <- run(handle, remove(root, obsolete)),
         {:ok, installed} <- install_selected(handle, runtime_module, root, selected, managed) do
      Managoat.Sandbox.write_file(handle, manifest, Jason.encode!(installed))
    end
  end

  # Stable across content and ref edits: a retained remote skill stays usable
  # when its best-effort reinstall is refused by the network policy.
  defp identity(skill), do: Jason.encode!([skill["source"], skill["name"]])

  defp normalize(skills),
    do: Enum.map(skills || [], fn s -> Map.new(s, fn {k, v} -> {to_string(k), v} end) end)

  defp named_manifest(skills),
    do: Map.new(normalize(skills), fn s -> {identity(s), names(s)} end)

  # skills.sh records globally installed names by source, including installs
  # made without --skill. Recover those on disks predating Fountain's own
  # manifest. Format: https://github.com/vercel-labs/skills/blob/main/src/skill-lock.ts
  defp legacy_manifest(handle, previous) do
    unnamed = Enum.filter(normalize(previous), &(is_binary(&1["source"]) and is_nil(&1["name"])))

    if unnamed == [] do
      {:ok, named_manifest(previous)}
    else
      script = ~S"""
      if [ -n "${XDG_STATE_HOME:-}" ]; then
        skills_lock="$XDG_STATE_HOME/skills/.skill-lock.json"
      else
        skills_lock="$HOME/.agents/.skill-lock.json"
      fi
      if [ -f "$skills_lock" ]; then cat -- "$skills_lock"; fi
      """

      with {:ok, raw} <- run(handle, script) do
        locked =
          case Jason.decode(raw) do
            {:ok, %{"skills" => skills}} when is_map(skills) -> skills
            _ -> %{}
          end

        recovered =
          Map.new(unnamed, fn entry ->
            names =
              Enum.flat_map(locked, fn
                {name, %{"source" => source, "sourceType" => "github"}} ->
                  if source == entry["source"] and safe_name?(name), do: [name], else: []

                _ ->
                  []
              end)

            {identity(entry), names}
          end)

        {:ok, Map.merge(named_manifest(previous), recovered)}
      end
    end
  end

  defp decode_manifest(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) ->
        Map.new(map, fn {key, values} ->
          {key, if(is_list(values), do: Enum.filter(values, &safe_name?/1), else: [])}
        end)

      _ ->
        %{}
    end
  end

  # A name is obsolete when it belonged to a skill that is no longer selected
  # and no selected skill claims it. Two skills can produce the same directory
  # name, so a retained claim always wins over a dropped one.
  defp obsolete_names(managed, selected) do
    wanted = named_manifest(selected)
    retained = managed |> Map.take(Map.keys(wanted)) |> Map.values() |> List.flatten()
    removed = managed |> Map.drop(Map.keys(wanted)) |> Map.values() |> List.flatten()
    Enum.uniq(removed -- (retained ++ (wanted |> Map.values() |> List.flatten())))
  end

  defp install_selected(handle, runtime, root, selected, managed) do
    {inline, remote} = Enum.split_with(normalize(selected), &is_binary(&1["content"]))

    # GitHub installs first, as in the library: their blocking exec is also the
    # readiness barrier before the sandbox accepts inline file writes.
    Enum.reduce_while(remote ++ inline, {:ok, %{}}, fn skill, {:ok, installed} ->
      case install_skill(handle, runtime, root, skill, managed) do
        {:ok, names} -> {:cont, {:ok, Map.put(installed, identity(skill), names)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp install_skill(handle, runtime, _root, %{"content" => _} = skill, _managed) do
    with :ok <- Managoat.Runtimes.Skills.install(handle, [skill], runtime: runtime),
         do: {:ok, names(skill)}
  end

  # A remote install names its own directories, so they are read off the disk
  # rather than assumed. The names already recorded for this skill are kept
  # too, so a reinstall the network refused does not make the copy on disk
  # look unowned and get deleted on the next pass.
  defp install_skill(handle, runtime, root, skill, managed) do
    with {:ok, before} <- run(handle, listing(root)),
         :ok <- Managoat.Runtimes.Skills.install(handle, [skill], runtime: runtime),
         {:ok, after_install} <- run(handle, listing(root)) do
      {:ok,
       Enum.uniq(
         (entries(after_install) -- entries(before)) ++
           names(skill) ++ Map.get(managed, identity(skill), [])
       )}
    end
  end

  defp names(skill), do: if(safe_name?(skill["name"]), do: [skill["name"]], else: [])

  defp safe_name?(name) when is_binary(name),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, name)

  defp safe_name?(_), do: false
  defp entries(text), do: text |> String.split("\n", trim: true) |> Enum.filter(&safe_name?/1)

  defp remove(root, names) do
    "mkdir -p -- #{quote_shell(root)}\n" <>
      Enum.map_join(names, "\n", fn name -> "rm -rf -- #{quote_shell(Path.join(root, name))}" end)
  end

  defp listing(root) do
    """
    for path in #{quote_shell(root)}/*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      basename -- "$path"
    done
    """
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp run(handle, script) do
    case Managoat.Sandbox.exec(handle, "bash", ["-c", script], stderr_to_stdout: true) do
      {:ok, output, 0} -> {:ok, output}
      {:ok, _output, code} -> {:error, "skill reconciliation exited with #{code}"}
      {:error, reason} -> {:error, reason}
    end
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
