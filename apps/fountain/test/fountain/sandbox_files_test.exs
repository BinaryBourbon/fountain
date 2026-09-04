defmodule Fountain.SandboxFilesTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Crypto
  alias Fountain.Environments
  alias Fountain.SandboxFiles

  @home "/home/sprite"

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")
    sandbox = insert_sandbox(user_id: user.id, status: "ready", agent_id: agent.id)
    {:ok, user: user, agent: agent, sandbox: sandbox}
  end

  # The fixed argv shape every script is run with: the path and flags are
  # positional parameters after the script, never interpolated into it.
  defp expect_script(fun) do
    expect(Managoat.Sandbox, :exec, fn handle,
                                       "bash",
                                       ["-c", script, "fountain-files" | args],
                                       opts ->
      assert opts[:timeout] == 30_000
      fun.(handle, script, args)
    end)
  end

  defp b64(bytes), do: Base.encode64(bytes)

  # `XY path\0`: one record of git's porcelain v1 under `-z`.
  defp record(code, path), do: code <> " " <> path <> <<0>>

  # The repository root and the branch, then the records as the script
  # passes them through.
  defp status_output(branch, records, root \\ @home),
    do: "#{root}\n#{branch}\n" <> IO.iodata_to_binary(records)

  describe "resolve_path/2" do
    test "nil and relative paths resolve from the agent's working directory", ctx do
      assert {:ok, @home} = SandboxFiles.resolve_path(ctx.sandbox, nil)
      assert {:ok, @home <> "/src/app.ex"} = SandboxFiles.resolve_path(ctx.sandbox, "src/app.ex")
      assert {:ok, @home <> "/src"} = SandboxFiles.resolve_path(ctx.sandbox, "./src/../src")
    end

    test "an absolute path inside a root is kept, one outside is refused", ctx do
      assert {:ok, @home <> "/.env"} = SandboxFiles.resolve_path(ctx.sandbox, @home <> "/.env")

      assert {:error, :path_outside_sandbox} =
               SandboxFiles.resolve_path(ctx.sandbox, "/etc/passwd")

      assert {:error, :path_outside_sandbox} = SandboxFiles.resolve_path(ctx.sandbox, "../../etc")
      # A sibling that merely shares the prefix is not inside the root.
      assert {:error, :path_outside_sandbox} =
               SandboxFiles.resolve_path(ctx.sandbox, "/home/sprite2")
    end

    test "a NUL byte or invalid UTF-8 is an invalid path", ctx do
      assert {:error, :invalid_path} = SandboxFiles.resolve_path(ctx.sandbox, "a\0b")
      assert {:error, :invalid_path} = SandboxFiles.resolve_path(ctx.sandbox, <<0xFF, 0xFE>>)
      assert {:error, :invalid_path} = SandboxFiles.resolve_path(ctx.sandbox, 42)
    end

    test "a gemini sandbox works from its /tmp workspace and may read the home too", ctx do
      agent = insert_agent(user_id: ctx.user.id, runtime: "gemini")
      sandbox = insert_sandbox(user_id: ctx.user.id, status: "ready", agent_id: agent.id)

      assert SandboxFiles.cwd(sandbox) == "/tmp/gemini-workspace"
      assert SandboxFiles.roots(sandbox) == [@home, "/tmp/gemini-workspace"]
      assert {:ok, "/tmp/gemini-workspace/a.md"} = SandboxFiles.resolve_path(sandbox, "a.md")
      assert {:ok, @home <> "/x"} = SandboxFiles.resolve_path(sandbox, @home <> "/x")
      assert {:error, :path_outside_sandbox} = SandboxFiles.resolve_path(sandbox, "/tmp/other")
    end

    test "a sandbox whose agent is gone falls back to the home", ctx do
      sandbox = insert_sandbox(user_id: ctx.user.id, status: "ready")
      assert SandboxFiles.cwd(sandbox) == @home
    end
  end

  describe "list/2" do
    test "runs the listing script on the resolved path and sorts directories first", ctx do
      expect_script(fn handle, script, args ->
        assert handle.name == ctx.sandbox.sprite_name
        assert script =~ "shopt -s dotglob nullglob"
        assert args == [@home <> "/src"]

        {:ok,
         "file\t12\tREADME.md\0directory\t\tlib\0file\t3\t.env\0" <>
           "symlink\t\tlink\0directory\t\tAssets\0file\t\tbroken\0", 0}
      end)

      assert {:ok, %{path: @home <> "/src", truncated: false, entries: entries}} =
               SandboxFiles.list(ctx.sandbox, "src")

      assert Enum.map(entries, &{&1.name, &1.type, &1.size}) == [
               {"Assets", "directory", nil},
               {"lib", "directory", nil},
               {".env", "file", 3},
               {"broken", "file", nil},
               {"link", "symlink", nil},
               {"README.md", "file", 12}
             ]
    end

    test "a name with a tab or newline survives", ctx do
      expect_script(fn _, _, _ -> {:ok, "file\t1\todd\tname\0file\t2\ttwo\nlines\0", 0} end)

      assert {:ok, %{entries: [%{name: "odd\tname"}, %{name: "two\nlines"}]}} =
               SandboxFiles.list(ctx.sandbox, nil)
    end

    test "the script's exit codes become the caller's errors", ctx do
      expect_script(fn _, _, _ -> {:ok, "", 3} end)
      assert {:error, :path_not_found} = SandboxFiles.list(ctx.sandbox, "missing")

      expect_script(fn _, _, _ -> {:ok, "", 4} end)
      assert {:error, :not_a_directory} = SandboxFiles.list(ctx.sandbox, "README.md")

      expect_script(fn _, _, _ -> {:ok, "", 5} end)
      assert {:error, :path_unreadable} = SandboxFiles.list(ctx.sandbox, "locked")

      expect_script(fn _, _, _ -> {:ok, "bash: boom", 127} end)

      assert {:error, {:sandbox_command_failed, 127, "bash: boom"}} =
               SandboxFiles.list(ctx.sandbox, nil)
    end

    test "a provider error is unreachable, and nothing runs on a parked sandbox", ctx do
      expect_script(fn _, _, _ -> {:error, {:unavailable, :timeout}} end)

      assert {:error, {:sandbox_unreachable, {:unavailable, :timeout}}} =
               SandboxFiles.list(ctx.sandbox, nil)

      reject(&Managoat.Sandbox.exec/4)
      parked = %{ctx.sandbox | status: "suspended"}
      assert {:error, {:sandbox_not_ready, "suspended"}} = SandboxFiles.list(parked, nil)
    end

    test "paths cross the adapter's host_path mapping", ctx do
      stub(Managoat.Sandbox, :host_path, fn _handle, path -> "/Users/me/box" <> path end)

      expect_script(fn _, _, args ->
        assert args == ["/Users/me/box/home/sprite/src"]
        {:ok, "", 0}
      end)

      # The response names the in-sandbox path, not the host one.
      assert {:ok, %{path: @home <> "/src", entries: []}} = SandboxFiles.list(ctx.sandbox, "src")
    end
  end

  describe "read/3" do
    test "decodes the size line and the base64 body, and redacts the identity's secrets", ctx do
      {:ok, dek} = Crypto.load_tenant_key(ctx.user.id)
      env = insert_env(user_id: ctx.user.id)

      {:ok, _} =
        Environments.upsert_secret(env, %{"key" => "API_TOKEN", "value" => "sk-live-abcdef"}, dek)

      # Too short to redact, on purpose: an eight-byte floor stops `true`
      # and `1` from scrubbing every file.
      {:ok, _} = Environments.upsert_secret(env, %{"key" => "DEBUG", "value" => "yes"}, dek)

      sandbox =
        insert_sandbox(
          user_id: ctx.user.id,
          status: "ready",
          environment_id: env.id,
          agent_id: ctx.agent.id
        )

      body = "token=sk-live-abcdef\ndebug=yes\n"

      expect_script(fn _, script, args ->
        assert script =~ "head -c"
        assert args == ["262144", @home <> "/.env"]
        {:ok, "#{byte_size(body)}\n" <> b64(body), 0}
      end)

      assert {:ok, file} = SandboxFiles.read(sandbox, ".env")

      assert file == %{
               path: @home <> "/.env",
               size: byte_size(body),
               truncated: false,
               encoding: "utf-8",
               content: "token=[REDACTED]\ndebug=yes\n"
             }
    end

    test "max_bytes is clamped, and a file longer than it is truncated", ctx do
      expect_script(fn _, _, args ->
        assert args == ["4194304", @home <> "/big"]
        {:ok, "9999999\n" <> b64("start"), 0}
      end)

      assert {:ok, %{size: 9_999_999, truncated: true, content: "start"}} =
               SandboxFiles.read(ctx.sandbox, "big", max_bytes: 99_999_999)
    end

    test "bytes that are not UTF-8 come back base64", ctx do
      bytes = <<0xFF, 0x00, 0x89, "PNG">>
      expect_script(fn _, _, _ -> {:ok, "6\n" <> b64(bytes), 0} end)

      assert {:ok, %{encoding: "base64", content: content}} =
               SandboxFiles.read(ctx.sandbox, "img.png")

      assert Base.decode64!(content) == bytes
    end

    test "a directory, a missing file and an unreadable one are named", ctx do
      expect_script(fn _, _, _ -> {:ok, "", 4} end)
      assert {:error, :is_a_directory} = SandboxFiles.read(ctx.sandbox, "src")

      expect_script(fn _, _, _ -> {:ok, "", 3} end)
      assert {:error, :path_not_found} = SandboxFiles.read(ctx.sandbox, "nope")

      expect_script(fn _, _, _ -> {:ok, "", 5} end)
      assert {:error, :path_unreadable} = SandboxFiles.read(ctx.sandbox, "root-only")
    end

    test "output the script did not produce is a command failure, not a crash", ctx do
      expect_script(fn _, _, _ -> {:ok, "not a size\n!!!", 0} end)
      assert {:error, {:sandbox_command_failed, 0, _}} = SandboxFiles.read(ctx.sandbox, "x")
    end
  end

  describe "diff/3" do
    test "runs git diff in the resolved directory with the ref and staged flag as parameters",
         ctx do
      diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"

      expect_script(fn _, script, args ->
        assert script =~ "git --no-pager --no-optional-locks diff --no-color --no-ext-diff"
        assert args == [@home <> "/repo", "262145", "main", "1"]
        {:ok, "#{@home}/repo\n" <> b64(diff), 0}
      end)

      assert {:ok,
              %{
                path: @home <> "/repo",
                repo_root: @home <> "/repo",
                staged: true,
                ref: "main",
                diff: ^diff,
                truncated: false
              }} = SandboxFiles.diff(ctx.sandbox, "repo", staged: true, ref: "main")
    end

    test "no ref and no staged flag pass as empty and 0", ctx do
      expect_script(fn _, _, args ->
        assert args == [@home, "262145", "", "0"]
        {:ok, "#{@home}\n" <> b64(""), 0}
      end)

      assert {:ok, %{ref: nil, staged: false, diff: ""}} = SandboxFiles.diff(ctx.sandbox, nil)
    end

    test "a ref that could read as a flag or a range is refused before anything runs", ctx do
      reject(&Managoat.Sandbox.exec/4)
      assert {:error, :invalid_ref} = SandboxFiles.diff(ctx.sandbox, nil, ref: "--output=/tmp/x")
      assert {:error, :invalid_ref} = SandboxFiles.diff(ctx.sandbox, nil, ref: "main..dev")
      assert {:error, :invalid_ref} = SandboxFiles.diff(ctx.sandbox, nil, ref: "a b")
    end

    test "the cap is one byte past max_bytes so an exact fit is not truncated", ctx do
      expect_script(fn _, _, [_, "6", _, _] -> {:ok, "/r\n" <> b64("abcdefg"), 0} end)

      assert {:ok, %{diff: "abcde", truncated: true}} =
               SandboxFiles.diff(ctx.sandbox, nil, max_bytes: 5)

      expect_script(fn _, _, [_, "6", _, _] -> {:ok, "/r\n" <> b64("abcde"), 0} end)

      assert {:ok, %{diff: "abcde", truncated: false}} =
               SandboxFiles.diff(ctx.sandbox, nil, max_bytes: 5)
    end

    test "a latin-1 hunk is recoded rather than refused", ctx do
      expect_script(fn _, _, _ -> {:ok, "/r\n" <> b64(<<"caf", 0xE9>>), 0} end)
      assert {:ok, %{diff: "café"}} = SandboxFiles.diff(ctx.sandbox, nil)
    end

    test "not a repository, an unknown ref and a missing directory are named", ctx do
      expect_script(fn _, _, _ -> {:ok, "", 6} end)
      assert {:error, :not_a_repository} = SandboxFiles.diff(ctx.sandbox, "plain")

      expect_script(fn _, _, _ -> {:ok, "", 7} end)
      assert {:error, :ref_not_found} = SandboxFiles.diff(ctx.sandbox, nil, ref: "nope")

      expect_script(fn _, _, _ -> {:ok, "", 3} end)
      assert {:error, :path_not_found} = SandboxFiles.diff(ctx.sandbox, "gone")

      expect_script(fn _, _, _ -> {:ok, "", 4} end)
      assert {:error, :not_a_directory} = SandboxFiles.diff(ctx.sandbox, "file.txt")
    end

    test "the diff is redacted with what a live conversation registered", ctx do
      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: ctx.sandbox,
          status: "running"
        )

      Fountain.Conversations.Redaction.put(conv.id, [{"ANTHROPIC_API_KEY", "sk-ant-secret-value"}])

      on_exit(fn -> Fountain.Conversations.Redaction.delete(conv.id) end)

      expect_script(fn _, _, _ -> {:ok, "/r\n" <> b64("+key = sk-ant-secret-value\n"), 0} end)
      assert {:ok, %{diff: "+key = [REDACTED]\n"}} = SandboxFiles.diff(ctx.sandbox, nil)
    end
  end

  describe "status/3" do
    test "reports an untracked file, the one state a diff cannot show", ctx do
      expect_script(fn _, script, args ->
        assert script =~ "git --no-pager --no-optional-locks status --porcelain=v1 -z"
        assert args == [@home <> "/repo", "1048577", "normal"]

        {:ok,
         status_output("main", [
           record("??", "notes.md"),
           record(" M", "lib/app.ex"),
           record("A ", "lib/new.ex"),
           record("MM", "mix.exs"),
           record(" D", "gone.txt"),
           record("UU", "conflict.ex")
         ]), 0}
      end)

      assert {:ok,
              %{
                path: @home <> "/repo",
                repo_root: @home,
                branch: "main",
                untracked: "normal",
                truncated: false,
                entries: entries
              }} = SandboxFiles.status(ctx.sandbox, "repo")

      # Both porcelain columns, read separately: `MM` is staged and then
      # edited again, `??` is untracked on both sides the way git reports it.
      assert Enum.map(entries, &{&1.path, &1.index, &1.worktree}) == [
               {"conflict.ex", "unmerged", "unmerged"},
               {"gone.txt", "unchanged", "deleted"},
               {"lib/app.ex", "unchanged", "modified"},
               {"lib/new.ex", "added", "unchanged"},
               {"mix.exs", "modified", "modified"},
               {"notes.md", "untracked", "untracked"}
             ]
    end

    test "a rename takes the record after it as its origin, destination first", ctx do
      expect_script(fn _, _, _ ->
        {:ok,
         status_output("main", [
           record("R ", "lib/new.ex"),
           "lib/old.ex" <> <<0>>,
           record(" M", "z.txt")
         ]), 0}
      end)

      assert {:ok, %{entries: entries}} = SandboxFiles.status(ctx.sandbox, nil)

      assert entries == [
               %{
                 path: "lib/new.ex",
                 index: "renamed",
                 worktree: "unchanged",
                 renamed_from: "lib/old.ex"
               },
               %{path: "z.txt", index: "unchanged", worktree: "modified", renamed_from: nil}
             ]
    end

    test "the untracked mode is one of three, and anything else reads as normal", ctx do
      for mode <- ~w(all no normal) do
        expect_script(fn _, _, [_, _, passed] ->
          assert passed == mode
          {:ok, status_output("main", []), 0}
        end)

        assert {:ok, %{untracked: ^mode}} = SandboxFiles.status(ctx.sandbox, nil, untracked: mode)
      end

      expect_script(fn _, _, [_, _, "normal"] -> {:ok, status_output("main", []), 0} end)

      assert {:ok, %{untracked: "normal", entries: []}} =
               SandboxFiles.status(ctx.sandbox, nil, untracked: "--ignored")
    end

    test "a detached HEAD has no branch, and a clean tree no entries", ctx do
      expect_script(fn _, _, _ -> {:ok, status_output("", []), 0} end)

      assert {:ok, %{branch: nil, entries: [], truncated: false}} =
               SandboxFiles.status(ctx.sandbox, nil)
    end

    test "a record the byte cap cut in half is dropped rather than half-read", ctx do
      expect_script(fn _, _, _ ->
        {:ok, status_output("main", [record(" M", "a.txt"), " M b.tx"]), 0}
      end)

      assert {:ok, %{entries: [%{path: "a.txt"}], truncated: true}} =
               SandboxFiles.status(ctx.sandbox, nil)
    end

    test "a cut that landed on a record boundary is still truncated", ctx do
      # Whole and NUL-terminated, so the tail cannot show this cut. Only the
      # byte past the cap can, which is why the script is asked for one.
      name = String.duplicate("x", 1_048_577 - 4)

      expect_script(fn _, _, _ ->
        {:ok, status_output("main", [record(" M", name)]), 0}
      end)

      assert {:ok, %{entries: [%{path: ^name}], truncated: true}} =
               SandboxFiles.status(ctx.sandbox, nil)
    end

    test "more changes than the entry cap are cut to it and flagged", ctx do
      records = for i <- 1..2_001, do: record(" M", "f#{i}.txt")
      expect_script(fn _, _, _ -> {:ok, status_output("main", records), 0} end)

      assert {:ok, %{entries: entries, truncated: true}} = SandboxFiles.status(ctx.sandbox, nil)
      assert length(entries) == 2_000
    end

    test "a record with a letter git does not write is skipped, not guessed at", ctx do
      expect_script(fn _, _, _ ->
        {:ok, status_output("main", [record("ZZ", "odd.txt"), record(" M", "ok.txt")]), 0}
      end)

      assert {:ok, %{entries: [%{path: "ok.txt"}]}} = SandboxFiles.status(ctx.sandbox, nil)
    end

    test "a path git wrote verbatim that is not UTF-8 is recoded, not refused", ctx do
      expect_script(fn _, _, _ ->
        {:ok, status_output("main", [record("??", <<"caf", 0xE9, ".md">>)]), 0}
      end)

      assert {:ok, %{entries: [%{path: "café.md"}]}} = SandboxFiles.status(ctx.sandbox, nil)
    end

    test "not a repository, a missing directory and a file are named", ctx do
      expect_script(fn _, _, _ -> {:ok, "", 6} end)
      assert {:error, :not_a_repository} = SandboxFiles.status(ctx.sandbox, "plain")

      expect_script(fn _, _, _ -> {:ok, "", 3} end)
      assert {:error, :path_not_found} = SandboxFiles.status(ctx.sandbox, "gone")

      expect_script(fn _, _, _ -> {:ok, "", 4} end)
      assert {:error, :not_a_directory} = SandboxFiles.status(ctx.sandbox, "file.txt")
    end

    test "output the script did not produce is a command failure, not a crash", ctx do
      expect_script(fn _, _, _ -> {:ok, "no second line", 0} end)
      assert {:error, {:sandbox_command_failed, 0, _}} = SandboxFiles.status(ctx.sandbox, nil)
    end

    test "a path is redacted the way file content is", ctx do
      {:ok, dek} = Crypto.load_tenant_key(ctx.user.id)
      env = insert_env(user_id: ctx.user.id)

      {:ok, _} =
        Environments.upsert_secret(env, %{"key" => "TOKEN", "value" => "sk-live-abcdef"}, dek)

      sandbox =
        insert_sandbox(
          user_id: ctx.user.id,
          status: "ready",
          environment_id: env.id,
          agent_id: ctx.agent.id
        )

      expect_script(fn _, _, _ ->
        {:ok,
         status_output("sk-live-abcdef-branch", [
           record("R ", "dump-sk-live-abcdef.json"),
           "old-sk-live-abcdef.json" <> <<0>>
         ]), 0}
      end)

      assert {:ok,
              %{
                branch: "[REDACTED]-branch",
                entries: [
                  %{path: "dump-[REDACTED].json", renamed_from: "old-[REDACTED].json"}
                ]
              }} = SandboxFiles.status(sandbox, nil)
    end
  end
end
