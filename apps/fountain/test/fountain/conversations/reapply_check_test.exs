defmodule Fountain.Conversations.ReapplyCheckTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations.Reapply
  alias Fountain.Environments

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id, setup_script: "echo build")

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        environment_id: env.id,
        build_fingerprint: Reapply.fingerprint(env)
      )

    %{user: user, env: env, sandbox: sandbox}
  end

  defp check(sandbox, opts) do
    Reapply.check(
      sandbox,
      Keyword.merge([current_runtime: "claude", target_runtime: "claude"], opts)
    )
  end

  test "a conversation with no machine yet has nothing to refuse" do
    assert :ok = Reapply.check(nil, current_runtime: "claude", target_runtime: "codex")
  end

  test "the same build inputs are applicable in place", ctx do
    # Only the variables differ, and those reach the machine on its next spawn.
    {:ok, sibling} =
      Environments.update_environment(ctx.env, %{"env_vars" => %{"WHO" => "sibling"}})

    assert :ok = check(ctx.sandbox, target_environment: sibling, built_with: ctx.env)
  end

  test "a different runtime is refused before anything else is compared", ctx do
    assert {:error, {:rebuild_required, :runtime}} =
             check(ctx.sandbox,
               target_runtime: "codex",
               target_environment: ctx.env,
               built_with: ctx.env
             )
  end

  test "each build field names itself when the selection moves to another environment", ctx do
    # `built_with` is the environment the machine was built from and
    # `target_environment` the one being asked for, so the field is nameable
    # only while those are two different rows. The refresh case is below.
    cases = [
      {%{"packages" => %{"apt" => ["ripgrep"]}}, :packages},
      {%{
         "repositories" => [
           %{"url" => "https://example.com/r.git", "mount_path" => "/home/sprite/r"}
         ]
       }, :repositories},
      {%{"setup_script" => "echo something else"}, :setup_script},
      {%{"networking_type" => "limited", "networking_config" => %{"allow" => ["a.test"]}},
       :networking}
    ]

    for {change, field} <- cases do
      {:ok, rebuilt} = Environments.update_environment(ctx.env, change)

      assert {:error, {:rebuild_required, ^field}} =
               check(ctx.sandbox, target_environment: rebuilt, built_with: ctx.env)
    end
  end

  test "a refresh of an environment edited in place cannot name the field", ctx do
    # The per-field cases above rebind to a second environment, which is not
    # what a refresh does: the production call site reads both sides from the
    # database, so a refresh passes the same row twice. The digest stored at
    # build time still catches that the build inputs moved; no field can be
    # singled out, and the refusal is the general one. Pinned so the behaviour
    # is deliberate rather than incidental — `check/2` says why.
    {:ok, edited} =
      Environments.update_environment(ctx.env, %{"packages" => %{"apt" => ["ripgrep"]}})

    assert {:error, {:rebuild_required, :environment}} =
             check(ctx.sandbox, target_environment: edited, built_with: edited)
  end

  test "dropping the environment altogether needs the disk built again", ctx do
    assert {:error, {:rebuild_required, :environment}} =
             check(ctx.sandbox, target_environment: nil, built_with: ctx.env)
  end

  test "a row that predates the digest falls back to the environment it records", ctx do
    # `build_fingerprint` is null on every row built before #1565. The
    # environment the sandbox names stands in, so a selection pointing at a
    # different environment is still caught.
    legacy = %{ctx.sandbox | build_fingerprint: nil}
    {:ok, other} = Environments.update_environment(ctx.env, %{"setup_script" => "echo other"})

    assert :ok = check(legacy, target_environment: ctx.env, built_with: ctx.env)

    assert {:error, {:rebuild_required, :setup_script}} =
             check(legacy, target_environment: other, built_with: ctx.env)
  end

  test "a row that predates the digest and cannot name what it was built with", ctx do
    legacy = %{ctx.sandbox | build_fingerprint: nil}

    assert {:error, {:rebuild_required, :environment}} =
             check(legacy, target_environment: ctx.env, built_with: nil)
  end

  test "every blocker has a sentence of its own" do
    blockers = [
      :runtime,
      :packages,
      :repositories,
      :setup_script,
      :networking,
      :environment,
      :shared_sandbox
    ]

    sentences = Enum.map(blockers, &Reapply.explain/1)
    assert Enum.all?(sentences, &is_binary/1)
    assert Enum.uniq(sentences) == sentences
  end
end
