defmodule Fountain.SandboxFiles do
  @moduledoc """
  Read-only views of a sandbox's disk for the apps that watch an agent work:
  a directory listing, one file's bytes, `git status` and `git diff`
  (ADR 0039).

  Three things this deliberately is not:

    * **Not exec.** The four operations are fixed scripts; the caller
      chooses a path and a few flags, never a command. Exec over the API
      would be a second I/O path beside ACP, unmetered (credits burn on
      turns), unredacted and, on a self-hosted runner, a shell on the
      user's own machine behind a bearer token.
    * **Not a new seam.** `Managoat.Sandbox` has `exec/4` on every adapter
      and no read primitive, so the scripts run through `exec` and every
      provider — Sprites, E2B, Daytona, the runner — is covered without an
      adapter change. Paths cross `Managoat.Sandbox.host_path/2` so the
      runner's `/home/sprite` mapping holds.
    * **Not a wake.** A parked sandbox costs nothing; a read that resumed
      it would cost provider time outside any turn. Anything but `ready`
      is refused with `{:sandbox_not_ready, status}`.

  Every path is confined to the sandbox home (`/home/sprite`) or the
  runtime's workspace (`Managoat.Runtimes.ACP.cwd/1`), and every byte that
  leaves goes through the same redaction the transcript gets: the values
  of the identity's environment and vault, plus whatever a live
  `ConversationServer` registered, replaced with `[REDACTED]`. The
  `.env` file is on that disk in plaintext, so this is what keeps a
  third-party app holding the user's key from reading the user's secrets
  back through it.

  Callers hand in a sandbox from the tenant-scoped
  `Fountain.Conversations.get_sandbox/2`; ownership is theirs to establish.
  """

  import Ecto.Query, only: [from: 2]

  alias Fountain.Conversations
  alias Fountain.Conversations.Conversation
  alias Fountain.Conversations.Redaction
  alias Fountain.Conversations.Sandbox
  alias Fountain.Crypto
  alias Fountain.Environments
  alias Fountain.Repo
  alias Fountain.Vaults

  @home "/home/sprite"
  @default_max_bytes 262_144
  @max_max_bytes 4_194_304
  @max_entries 2_000
  # Status is listing-shaped, so the caller's bound is `@max_entries`, not a
  # byte count. This is the guard behind it: `-uall` on a repository with an
  # unignored build tree can emit far more than the entry cap will keep, and
  # the whole stream is read into memory before anything counts it.
  @max_status_bytes 1_048_576
  @timeout 30_000
  @ref_pattern ~r|\A[A-Za-z0-9][A-Za-z0-9._/~^@{}-]*\z|

  # Exit codes the scripts reserve. Anything else nonzero is the command
  # itself failing, surfaced with its output.
  @exit_missing 3
  @exit_wrong_kind 4
  @exit_unreadable 5
  @exit_not_repository 6
  @exit_ref_not_found 7

  # The porcelain v1 status letters, one per side. `change_states/0` is these
  # values, so the vocabulary is written once.
  @states %{
    " " => "unchanged",
    "M" => "modified",
    "T" => "type_changed",
    "A" => "added",
    "D" => "deleted",
    "R" => "renamed",
    "C" => "copied",
    "U" => "unmerged",
    "?" => "untracked",
    "!" => "ignored"
  }

  @typedoc "A directory entry."
  @type entry :: %{name: String.t(), type: String.t(), size: non_neg_integer() | nil}

  @typedoc """
  One path `git status` reports, with the index and the working tree read
  separately. `renamed_from` is set only when that side is a rename or a copy.
  """
  @type change :: %{
          path: String.t(),
          index: String.t(),
          worktree: String.t(),
          renamed_from: String.t() | nil
        }

  @type error ::
          {:sandbox_not_ready, String.t()}
          | :invalid_path
          | :path_outside_sandbox
          | :path_not_found
          | :not_a_directory
          | :is_a_directory
          | :path_unreadable
          | :not_a_repository
          | :invalid_ref
          | :ref_not_found
          | {:sandbox_unreachable, term()}
          | {:sandbox_command_failed, integer(), String.t()}

  @doc "What the listing script classifies an entry as."
  @spec entry_types() :: [String.t()]
  def entry_types, do: ~w(file directory symlink other)

  @doc "How a file's bytes travel: the text itself, or base64 when not UTF-8."
  @spec encodings() :: [String.t()]
  def encodings, do: ~w(utf-8 base64)

  @doc """
  How `git status` describes one side of a path, its porcelain letter in
  words. An untracked path reads `untracked` on both sides, because that is
  what git reports for it (`??`), and it is the one state `diff/3` cannot
  show at all.
  """
  @spec change_states() :: [String.t()]
  def change_states, do: @states |> Map.values() |> Enum.sort()

  @doc """
  What a caller may ask `git status` to do about untracked paths: collapse an
  untracked directory to one entry (`normal`), list every file under it
  (`all`), or leave them out (`no`).
  """
  @spec untracked_modes() :: [String.t()]
  def untracked_modes, do: ~w(normal all no)

  @doc "The largest `max_bytes` a read accepts."
  @spec max_max_bytes() :: pos_integer()
  def max_max_bytes, do: @max_max_bytes

  @doc "The read size when the caller names none."
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @doc """
  The directories a path may live under: the sandbox home and the
  runtime's working directory (the same for claude and codex, `/tmp/…` for
  gemini and opencode).
  """
  @spec roots(Sandbox.t()) :: [String.t()]
  def roots(%Sandbox{} = sandbox), do: Enum.uniq([@home, cwd(sandbox)])

  @doc """
  Where a relative path resolves from — the agent's working directory.
  """
  @spec cwd(Sandbox.t()) :: String.t()
  def cwd(%Sandbox{} = sandbox) do
    case with_agent(sandbox) do
      %Sandbox{agent: %{runtime: runtime}} when is_binary(runtime) ->
        Managoat.Runtimes.ACP.cwd(runtime)

      _ ->
        @home
    end
  end

  @doc """
  Resolve a caller's path against the sandbox: relative to `cwd/1`,
  normalised, and refused unless it is one of `roots/1` or inside one.
  `nil` is the working directory itself.
  """
  @spec resolve_path(Sandbox.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_outside_sandbox}
  def resolve_path(%Sandbox{} = sandbox, nil), do: {:ok, cwd(sandbox)}
  def resolve_path(%Sandbox{} = sandbox, ""), do: {:ok, cwd(sandbox)}

  def resolve_path(%Sandbox{} = sandbox, path) when is_binary(path) do
    if String.contains?(path, <<0>>) or not String.valid?(path) do
      {:error, :invalid_path}
    else
      absolute = Path.expand(path, cwd(sandbox))

      if Enum.any?(roots(sandbox), &under?(absolute, &1)),
        do: {:ok, absolute},
        else: {:error, :path_outside_sandbox}
    end
  end

  def resolve_path(%Sandbox{}, _other), do: {:error, :invalid_path}

  @doc """
  The entries of a directory, directories first then by name. `path` is
  `nil` for the working directory. At most #{@max_entries} entries are
  returned; `truncated` says whether there were more.
  """
  @spec list(Sandbox.t(), String.t() | nil) ::
          {:ok, %{path: String.t(), entries: [entry()], truncated: boolean()}} | {:error, error()}
  def list(%Sandbox{} = sandbox, path) do
    with :ok <- ready?(sandbox),
         {:ok, absolute} <- resolve_path(sandbox, path),
         {:ok, output} <- run(sandbox, list_script(), [absolute]) do
      entries = parse_entries(output)

      {:ok,
       %{
         path: absolute,
         entries: Enum.take(entries, @max_entries),
         truncated: length(entries) > @max_entries
       }}
    end
  end

  @doc """
  One file's bytes, redacted, at most `opts[:max_bytes]` of them (default
  #{@default_max_bytes}, at most #{@max_max_bytes}). `content` is the text
  itself when it is valid UTF-8 (`encoding: "utf-8"`) and base64 otherwise
  (`encoding: "base64"`); `size` is the whole file and `truncated` says
  whether `content` stopped short of it.
  """
  @spec read(Sandbox.t(), String.t(), keyword()) ::
          {:ok,
           %{
             path: String.t(),
             size: non_neg_integer(),
             truncated: boolean(),
             encoding: String.t(),
             content: String.t()
           }}
          | {:error, error()}
  def read(%Sandbox{} = sandbox, path, opts \\ []) do
    max_bytes = opts |> Keyword.get(:max_bytes) |> clamp_max_bytes()

    with :ok <- ready?(sandbox),
         {:ok, absolute} <- resolve_path(sandbox, path),
         {:ok, output} <- run(sandbox, read_script(), [Integer.to_string(max_bytes), absolute]),
         {:ok, size, bytes} <- parse_read(output) do
      bytes = redact(sandbox, bytes)
      {encoding, content} = encode(bytes)

      {:ok,
       %{
         path: absolute,
         size: size,
         truncated: size > max_bytes,
         encoding: encoding,
         content: content
       }}
    end
  end

  @doc """
  `git diff` of the repository at `path` (any directory inside it), redacted.
  `opts[:staged]` compares the index instead of the working tree
  (`--cached`); `opts[:ref]` compares against a commit, branch or tag.
  `opts[:max_bytes]` caps the text like `read/3`.
  """
  @spec diff(Sandbox.t(), String.t() | nil, keyword()) ::
          {:ok,
           %{
             path: String.t(),
             repo_root: String.t(),
             staged: boolean(),
             ref: String.t() | nil,
             diff: String.t(),
             truncated: boolean()
           }}
          | {:error, error()}
  def diff(%Sandbox{} = sandbox, path, opts \\ []) do
    max_bytes = opts |> Keyword.get(:max_bytes) |> clamp_max_bytes()
    staged = Keyword.get(opts, :staged, false) == true
    ref = Keyword.get(opts, :ref)

    with :ok <- ready?(sandbox),
         {:ok, ref} <- validate_ref(ref),
         {:ok, absolute} <- resolve_path(sandbox, path),
         # One byte past the cap tells truncation from an exact fit.
         {:ok, output} <-
           run(sandbox, diff_script(), [
             absolute,
             Integer.to_string(max_bytes + 1),
             ref || "",
             if(staged, do: "1", else: "0")
           ]),
         {:ok, root, bytes} <- parse_diff(output) do
      truncated = byte_size(bytes) > max_bytes

      text =
        bytes |> binary_part(0, min(byte_size(bytes), max_bytes)) |> then(&redact(sandbox, &1))

      {:ok,
       %{
         path: absolute,
         repo_root: root,
         staged: staged,
         ref: ref,
         diff: to_text(text),
         truncated: truncated
       }}
    end
  end

  @doc """
  `git status` of the repository at `path`, one entry per changed path.

  This is the view that shows a file the agent made and never staged:
  `diff/3` compares tracked content, so an untracked file is invisible to it
  whatever flags it is given. A deletion is visible to both.

  Entries cover the whole repository whatever `path` names inside it, and
  each entry's `path` is relative to `repo_root` — that is what git's
  porcelain reports, and it is not the shape `list/2` and `read/3` use.
  `index` and `worktree` are the two porcelain columns read separately, so a
  file staged and then edited again reports both. `opts[:untracked]` is one
  of `untracked_modes/0`; anything else reads as the default, `"normal"`.
  """
  @spec status(Sandbox.t(), String.t() | nil, keyword()) ::
          {:ok,
           %{
             path: String.t(),
             repo_root: String.t(),
             branch: String.t() | nil,
             untracked: String.t(),
             entries: [change()],
             truncated: boolean()
           }}
          | {:error, error()}
  def status(%Sandbox{} = sandbox, path, opts \\ []) do
    untracked = untracked_mode(Keyword.get(opts, :untracked))

    with :ok <- ready?(sandbox),
         {:ok, absolute} <- resolve_path(sandbox, path),
         # One byte past the cap, like `diff/3`: it tells a stream that was
         # cut from one that ended on the boundary.
         {:ok, output} <-
           run(sandbox, status_script(), [
             absolute,
             Integer.to_string(@max_status_bytes + 1),
             untracked
           ]),
         {:ok, root, branch, body} <- parse_status(output) do
      {records, cut?} = status_records(body)
      changes = parse_changes(records)
      values = secret_values(sandbox)

      {:ok,
       %{
         path: absolute,
         repo_root: root,
         branch: branch && to_text(redact_with(values, branch)),
         untracked: untracked,
         entries: changes |> Enum.take(@max_entries) |> Enum.map(&redact_change(values, &1)),
         truncated: cut? or length(changes) > @max_entries
       }}
    end
  end

  # ── guards ─────────────────────────────────────────────────────────────

  defp ready?(%Sandbox{status: "ready"}), do: :ok
  defp ready?(%Sandbox{status: status}), do: {:error, {:sandbox_not_ready, status}}

  defp under?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  # Like `clamp_max_bytes/1`: an unknown value reads as the default rather
  # than as an error. The API's own enum refuses a typo before this, so the
  # fallback only serves a direct caller of the context.
  defp untracked_mode(mode) when is_binary(mode) do
    if mode in untracked_modes(), do: mode, else: "normal"
  end

  defp untracked_mode(_), do: "normal"

  defp clamp_max_bytes(nil), do: @default_max_bytes
  defp clamp_max_bytes(n) when is_integer(n) and n > 0, do: min(n, @max_max_bytes)
  defp clamp_max_bytes(_), do: @default_max_bytes

  # The shape of a revision, not its existence — the script asks git that
  # (`ref_not_found`). No leading `-`, so a ref can never read as a flag.
  defp validate_ref(nil), do: {:ok, nil}
  defp validate_ref(""), do: {:ok, nil}

  defp validate_ref(ref) when is_binary(ref) do
    if Regex.match?(@ref_pattern, ref) and not String.contains?(ref, ".."),
      do: {:ok, ref},
      else: {:error, :invalid_ref}
  end

  defp validate_ref(_), do: {:error, :invalid_ref}

  defp with_agent(%Sandbox{agent: %Ecto.Association.NotLoaded{}} = sandbox),
    do: Repo.preload(sandbox, :agent)

  defp with_agent(%Sandbox{} = sandbox), do: sandbox

  # ── running the scripts ────────────────────────────────────────────────

  # `bash -c SCRIPT NAME ARGS…`: the path and flags are positional
  # parameters, never interpolated into the script, so a filename is data
  # whatever it contains. Paths cross `host_path/2` for the runner.
  defp run(%Sandbox{} = sandbox, script, args) do
    handle =
      Managoat.Sandbox.build_handle(
        Conversations.sandbox_provider_atom(sandbox),
        sandbox.sprite_name
      )

    args = Enum.map(args, &map_path(handle, &1))

    case Managoat.Sandbox.exec(handle, "bash", ["-c", script, "fountain-files" | args],
           timeout: @timeout
         ) do
      {:ok, output, 0} -> {:ok, output}
      {:ok, _output, @exit_missing} -> {:error, :path_not_found}
      {:ok, _output, @exit_unreadable} -> {:error, :path_unreadable}
      {:ok, _output, @exit_not_repository} -> {:error, :not_a_repository}
      {:ok, _output, @exit_ref_not_found} -> {:error, :ref_not_found}
      {:ok, output, @exit_wrong_kind} -> {:error, wrong_kind(script, output)}
      {:ok, output, code} -> {:error, {:sandbox_command_failed, code, redact(sandbox, output)}}
      {:error, reason} -> {:error, {:sandbox_unreachable, reason}}
    end
  end

  defp map_path(handle, "/" <> _ = path), do: Managoat.Sandbox.host_path(handle, path)
  defp map_path(_handle, other), do: other

  # The read script's wrong-kind is a directory; the other two want one.
  defp wrong_kind(script, _output) do
    if script == read_script(), do: :is_a_directory, else: :not_a_directory
  end

  # `type \t size \t name \0` per entry; the name goes last so a tab in it
  # survives, and NUL ends it so a newline does too.
  defp list_script do
    ~S"""
    p=$1
    [ -e "$p" ] || exit 3
    [ -d "$p" ] || exit 4
    cd -- "$p" 2>/dev/null || exit 5
    shopt -s dotglob nullglob
    for f in *; do
      if [ -L "$f" ]; then t=symlink
      elif [ -d "$f" ]; then t=directory
      elif [ -f "$f" ]; then t=file
      else t=other; fi
      s=
      if [ "$t" = file ]; then s=$(wc -c < "$f" 2>/dev/null | tr -d ' '); fi
      printf '%s\t%s\t%s\0' "$t" "$s" "$f"
    done
    """
  end

  # The size on the first line, then the first N bytes base64-encoded, so
  # the bytes survive whichever transport an adapter streams stdout over.
  defp read_script do
    ~S"""
    n=$1
    p=$2
    [ -e "$p" ] || exit 3
    [ -d "$p" ] && exit 4
    [ -r "$p" ] || exit 5
    wc -c < "$p" | tr -d ' '
    head -c "$n" "$p" | base64
    """
  end

  # The repository root on the first line, then the diff base64-encoded.
  # The ref is verified first because a pipeline's status is `base64`'s,
  # which would turn an unknown ref into an empty diff. `--no-optional-locks`
  # keeps a read from contending with the agent's own git for the index.
  defp diff_script do
    ~S"""
    d=$1
    n=$2
    ref=$3
    staged=$4
    [ -e "$d" ] || exit 3
    [ -d "$d" ] || exit 4
    cd -- "$d" 2>/dev/null || exit 5
    root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 6
    if [ -n "$ref" ]; then
      git rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || exit 7
    fi
    printf '%s\n' "$root"
    if [ "$staged" = 1 ]; then set -- --cached; else set --; fi
    if [ -n "$ref" ]; then set -- "$@" "$ref"; fi
    git --no-pager --no-optional-locks diff --no-color --no-ext-diff "$@" | head -c "$n" | base64
    """
  end

  # The repository root and the branch on the first two lines, then the
  # porcelain records as they come: `-z` already frames them with NUL, so
  # unlike a file's bytes they need no base64 to survive a transport.
  #
  # The branch is asked for separately rather than parsed out of the `-b`
  # header, whose one line has to carry "no branch", "no commits yet" and an
  # ahead/behind suffix; an empty second line is a detached HEAD.
  # `--no-optional-locks` matters more here than for a diff, because a plain
  # `git status` refreshes the index: without it a read takes `index.lock`
  # and breaks the agent's own commit.
  #
  # The mode chooses between fixed flags rather than reaching the command
  # line, so caller data is never adjacent to a `--`.
  defp status_script do
    ~S"""
    d=$1
    n=$2
    untracked=$3
    [ -e "$d" ] || exit 3
    [ -d "$d" ] || exit 4
    cd -- "$d" 2>/dev/null || exit 5
    root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 6
    branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
    printf '%s\n%s\n' "$root" "$branch"
    case $untracked in
      all) set -- --untracked-files=all ;;
      no) set -- --untracked-files=no ;;
      *) set -- --untracked-files=normal ;;
    esac
    git --no-pager --no-optional-locks status --porcelain=v1 -z "$@" | head -c "$n"
    """
  end

  # ── parsing ────────────────────────────────────────────────────────────

  defp parse_entries(output) do
    output
    |> String.split(<<0>>, trim: true)
    |> Enum.flat_map(fn record ->
      case String.split(record, "\t", parts: 3) do
        [type, size, name] -> [%{name: name, type: type, size: parse_size(size)}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn %{name: name, type: type} ->
      {if(type == "directory", do: 0, else: 1), String.downcase(name), name}
    end)
  end

  defp parse_size(""), do: nil

  defp parse_size(size) do
    case Integer.parse(size) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_read(output) do
    with [size_line, encoded] <- String.split(output, "\n", parts: 2),
         {size, ""} <- Integer.parse(String.trim(size_line)),
         {:ok, bytes} <- Base.decode64(encoded, ignore: :whitespace) do
      {:ok, size, bytes}
    else
      _ -> {:error, {:sandbox_command_failed, 0, "unparseable read output"}}
    end
  end

  defp parse_diff(output) do
    with [root, encoded] <- String.split(output, "\n", parts: 2),
         {:ok, bytes} <- Base.decode64(encoded, ignore: :whitespace) do
      {:ok, String.trim(root), bytes}
    else
      _ -> {:error, {:sandbox_command_failed, 0, "unparseable diff output"}}
    end
  end

  defp parse_status(output) do
    case String.split(output, "\n", parts: 3) do
      [root, branch, body] -> {:ok, String.trim(root), blank_to_nil(branch), body}
      _ -> {:error, {:sandbox_command_failed, 0, "unparseable status output"}}
    end
  end

  defp blank_to_nil(branch) do
    case String.trim(branch) do
      "" -> nil
      name -> name
    end
  end

  # Only a NUL-terminated record is whole, so the last element of the split is
  # either the empty string (the stream ended on a boundary) or a record the
  # byte cap cut in half. Either way it is not an entry. A body one byte past
  # the cap is a cut that landed on a boundary, which the tail cannot show.
  defp status_records(body) do
    {tail, records} = body |> :binary.split(<<0>>, [:global]) |> List.pop_at(-1)
    {records, tail != "" or byte_size(body) > @max_status_bytes}
  end

  # `XY <path>`, and for a rename or a copy the origin follows as its own
  # record: `-z` drops git's arrow and reverses the pair, so the destination
  # comes first and the origin second.
  defp parse_changes(records), do: records |> parse_changes([]) |> Enum.sort_by(& &1.path)

  defp parse_changes([], acc), do: acc

  defp parse_changes([record | rest], acc) do
    case decode_record(record) do
      {:ok, change, :with_origin} ->
        case rest do
          # The origin was past the byte cap. Keep the destination and lose
          # the origin rather than read the next entry as one.
          [] -> parse_changes([], [change | acc])
          [origin | rest] -> parse_changes(rest, [%{change | renamed_from: origin} | acc])
        end

      {:ok, change, :plain} ->
        parse_changes(rest, [change | acc])

      :error ->
        parse_changes(rest, acc)
    end
  end

  defp decode_record(<<index::binary-1, worktree::binary-1, " ", path::binary>>)
       when path != "" do
    with {:ok, index_state} <- decode_state(index),
         {:ok, worktree_state} <- decode_state(worktree) do
      change = %{path: path, index: index_state, worktree: worktree_state, renamed_from: nil}
      origin? = index in ~w(R C) or worktree in ~w(R C)
      {:ok, change, if(origin?, do: :with_origin, else: :plain)}
    end
  end

  defp decode_record(_record), do: :error

  defp decode_state(letter), do: Map.fetch(@states, letter)

  # ── output ─────────────────────────────────────────────────────────────

  defp encode(bytes) do
    if String.valid?(bytes), do: {"utf-8", bytes}, else: {"base64", Base.encode64(bytes)}
  end

  # A diff is text by construction (git says "Binary files differ" for the
  # rest), but a latin-1 source file makes an invalid UTF-8 hunk; recode it
  # rather than refuse the whole diff.
  defp to_text(bytes) do
    if String.valid?(bytes), do: bytes, else: :unicode.characters_to_binary(bytes, :latin1)
  end

  # ── redaction ──────────────────────────────────────────────────────────

  defp redact(%Sandbox{} = sandbox, bytes) when is_binary(bytes),
    do: redact_with(secret_values(sandbox), bytes)

  # `secret_values/1` reads the vault and the environment, so a caller with
  # many strings to redact looks them up once and replaces many times.
  defp redact_with([], bytes), do: bytes

  defp redact_with(values, bytes),
    do: :binary.replace(bytes, values, Redaction.placeholder(), [:global])

  # A path is data the agent chose, so it goes through redaction like file
  # content does, and through `to_text/1` because git reports a name verbatim
  # and a byte sequence that is not UTF-8 would fail to encode as JSON.
  defp redact_change(values, change) do
    %{
      change
      | path: to_text(redact_with(values, change.path)),
        renamed_from: change.renamed_from && to_text(redact_with(values, change.renamed_from))
    }
  end

  # The identity's own values (what `.env` on that disk holds) plus what any
  # live server registered — the latter covers the inference credential and
  # the callback token, which come from Fountain rather than the identity.
  # Longest first, like `Redaction.put/2`, so a value that contains another
  # is replaced whole.
  defp secret_values(%Sandbox{} = sandbox) do
    (identity_values(sandbox) ++ registered_values(sandbox))
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= Redaction.min_length()))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp registered_values(%Sandbox{id: sandbox_id}) do
    from(c in Conversation, where: c.sandbox_id == ^sandbox_id, select: c.id)
    |> Repo.all()
    |> Enum.flat_map(&Redaction.lookup/1)
  end

  defp identity_values(%Sandbox{environment_id: nil, vault_id: nil}), do: []

  defp identity_values(%Sandbox{user_id: user_id} = sandbox) do
    case Crypto.load_tenant_key(user_id) do
      {:ok, dek} ->
        # Ownership: the sandbox row is the caller's (scoped get_sandbox);
        # its environment and vault are fetched scoped to the same tenant.
        env =
          sandbox.environment_id && Environments.get_environment(sandbox.environment_id, user_id)

        vault = sandbox.vault_id && Vaults.get_vault(sandbox.vault_id, user_id)

        env_values = if env, do: Map.values(Environments.decrypted_env(env, dek)), else: []
        vault_values = if vault, do: Map.values(Vaults.decrypted_env(vault, dek)), else: []
        env_values ++ vault_values

      _ ->
        []
    end
  end
end
