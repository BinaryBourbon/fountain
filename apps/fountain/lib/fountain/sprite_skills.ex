defmodule Fountain.SpriteSkills do
  @moduledoc """
  Materialize an agent's skills onto its sprite at provision time.

  Each entry in `skills` is one of:

    * `%{"name" => name, "content" => skill_md}` — inline. Written
      directly to `<runtime.skills_root>/<name>/SKILL.md`.
    * `%{"source" => "owner/repo", "name" => optional}` — github.
      Installed via the [skills.sh](https://skills.sh) CLI on the sprite:
      `npx -y skills@latest add <source> --global --agent <runtime-agent>
      --yes [--skill <name>]`. Each runtime declares its own
      `skills_sh_agent` so the CLI writes to the right on-disk layout.

  The bundled `fountain` skill at `priv/sprite_skills/fountain/SKILL.md` is
  always prepended as an inline skill — it's how the per-conversation callback
  API gets discovered inside the sprite.

  This must run before the network policy locks the sprite down: github
  installs hit npm + GitHub.
  """

  require Logger

  alias Fountain.Runtimes
  alias Sprites.Filesystem

  @bundle_root "sprite_skills"
  @fountain_skill_name "fountain"

  @doc """
  Mount `skills` (a list of inline/github maps) on `sprite` for the
  named runtime. The bundled `fountain` skill is always prepended.
  """
  def mount(sprite, runtime, skills) when is_binary(runtime) do
    case Runtimes.for_runtime(runtime) do
      {:ok, mod} -> mount(sprite, mod, skills)
      {:error, _} = err -> err
    end
  end

  def mount(sprite, runtime_module, skills) when is_atom(runtime_module) do
    skills_root = runtime_module.skills_root()
    sh_agent = runtime_module.skills_sh_agent()

    all = [fountain_inline_skill() | normalize(skills || [])]

    {inline, github} =
      Enum.split_with(all, fn s -> is_binary(s["content"]) end)

    fs = Sprites.filesystem(sprite, "/")
    write_inline_skills(fs, skills_root, inline)
    install_github_skills(sprite, sh_agent, github)
    :ok
  end

  defp normalize(skills) do
    skills
    |> Enum.map(fn entry ->
      Map.new(entry, fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)
    end)
  end

  defp fountain_inline_skill do
    %{
      "name" => @fountain_skill_name,
      "content" => File.read!(Path.join([priv_dir(), @fountain_skill_name, "SKILL.md"]))
    }
  end

  defp write_inline_skills(_fs, _root, []), do: :ok

  defp write_inline_skills(fs, root, inline) do
    Filesystem.mkdir_p(fs, root)

    Enum.each(inline, fn %{"name" => name, "content" => content} ->
      dir = Path.join(root, name)
      Filesystem.mkdir_p(fs, dir)
      Filesystem.write(fs, Path.join(dir, "SKILL.md"), content)
    end)
  end

  defp install_github_skills(_sprite, _agent_id, []), do: :ok

  defp install_github_skills(sprite, agent_id, github) do
    safe_agent = safe_token!(agent_id)

    Enum.each(github, fn entry ->
      source = safe_token!(entry["source"])

      cmd =
        "npx -y skills@latest add #{source} --global --agent #{safe_agent} --yes" <>
          case entry["name"] do
            nil -> ""
            "" -> ""
            name -> " --skill #{safe_token!(name)}"
          end

      {output, code} =
        Sprites.cmd(sprite, "bash", ["-lc", cmd],
          stderr_to_stdout: true,
          timeout: 120_000
        )

      if code != 0 do
        Logger.warning(
          "skills.sh install failed (#{code}) for #{inspect(entry)}: #{String.slice(output, 0, 500)}"
        )
      end
    end)
  end

  # Allow-list quoting guard for values interpolated into `bash -lc`.
  # Permits `[A-Za-z0-9._/-]` which is the full set needed for owner/repo
  # identifiers, skill names, and the short `--agent` strings the runtimes
  # declare. Anything else raises rather than silently passing through —
  # we never want a `;` or `$` smuggled into a shelled-out command.
  @doc false
  def safe_token!(value) when is_binary(value) do
    if Regex.match?(~r{\A[A-Za-z0-9._/-]+\z}, value) do
      value
    else
      raise ArgumentError, "unsafe skill token (rejected by allow-list): #{inspect(value)}"
    end
  end

  defp priv_dir do
    Path.join(:code.priv_dir(:fountain) |> to_string(), @bundle_root)
  end
end
