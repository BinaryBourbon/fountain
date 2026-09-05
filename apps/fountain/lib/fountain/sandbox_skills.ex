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
    reconcile(handle, runtime, skills, [])
  end

  @doc """
  Replace Fountain-managed skills, preserving other entries in the skills root.

  The on-disk manifest also captures names discovered by an unnamed GitHub
  install. `previous` seeds named skills on disks predating that manifest.
  """
  def reconcile(handle, runtime, skills, previous) do
    with {:ok, mod} <- runtime_module(runtime) do
      root = mod.skills_root()
      manifest = Path.join(root, ".fountain-managed-skills")
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
           {:ok, installed} <- install_selected(handle, runtime, root, selected, managed) do
        Managoat.Sandbox.write_file(handle, manifest, Jason.encode!(installed))
      end
    end
  end

  defp runtime_module(runtime) when is_binary(runtime),
    do: Managoat.Runtimes.for_runtime(runtime)

  defp runtime_module(runtime) when is_atom(runtime), do: {:ok, runtime}

  # Stable across content/ref edits: a retained remote skill remains usable if
  # its best-effort reinstall is refused by the machine's network policy.
  defp identity(skill), do: Jason.encode!([skill["source"], skill["name"]])

  defp normalize(skills),
    do: Enum.map(skills || [], fn s -> Map.new(s, fn {k, v} -> {to_string(k), v} end) end)

  defp named_manifest(skills),
    do: Map.new(normalize(skills), fn s -> {identity(s), names(s)} end)

  # skills.sh records globally installed names by source, including installs
  # without --skill. Recover those on disks predating Fountain's manifest.
  # Format: https://github.com/vercel-labs/skills/blob/main/src/skill-lock.ts
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
        skills =
          case Jason.decode(raw) do
            {:ok, %{"skills" => skills}} when is_map(skills) -> skills
            _ -> %{}
          end

        recovered =
          Map.new(unnamed, fn entry ->
            names =
              Enum.flat_map(skills, fn
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

  defp obsolete_names(managed, selected) do
    wanted = named_manifest(selected)
    retained = Map.take(managed, Map.keys(wanted)) |> Map.values() |> List.flatten()
    removed = Map.drop(managed, Map.keys(wanted)) |> Map.values() |> List.flatten()
    Enum.uniq(removed -- (retained ++ (Map.values(wanted) |> List.flatten())))
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

  # Only direct children are tracked. Neither a forged manifest nor a legacy
  # skill name may turn reconciliation into deletion outside the skills root.
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
