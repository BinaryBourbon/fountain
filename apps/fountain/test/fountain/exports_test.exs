defmodule Fountain.ExportsTest do
  @moduledoc """
  Self-serve account data export (#288).

  The properties that matter, in order: secret values never leave the system
  through an export, no tenant can read another tenant's artifact, the rate
  limit holds, and the download link actually expires.
  """

  use Fountain.DataCase, async: true

  import Ecto.Query

  alias Fountain.Audit
  alias Fountain.Exports
  alias Fountain.Exports.Export
  alias Fountain.Repo
  alias Fountain.Workers.AccountExport

  # The plaintext that must never appear in an export. Distinctive on purpose
  # so a substring assertion cannot pass by accident.
  @secret_value "hunter2-super-secret-export-canary"

  defp backdate(export, seconds) do
    {1, _} =
      Repo.update_all(
        from(e in Export, where: e.id == ^export.id),
        set: [
          inserted_at:
            DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)
        ]
      )

    Repo.get!(Export, export.id)
  end

  describe "request_export/2" do
    test "creates a pending export, enqueues the job, records the audit event" do
      user = insert_verified_user()

      assert {:ok, %Export{status: "pending"} = export} = Exports.request_export(user)

      assert_enqueued(
        worker: AccountExport,
        args: %{export_id: export.id, user_id: user.id}
      )

      # Filtered rather than matched as the whole trail: since #544 every
      # account opens with an `account.registered` row, so "the only event" is
      # no longer a thing a fresh user has.
      assert [event] =
               user.id
               |> Audit.list_recent_for_user(10)
               |> Enum.filter(&(&1.action == "account.export_requested"))

      assert event.action == "account.export_requested"
      assert event.resource_id == export.id
      assert event.actor == "self"
    end

    test "a second request within the hour is rate limited" do
      user = insert_verified_user()

      assert {:ok, _} = Exports.request_export(user)
      assert {:error, {:rate_limited, retry_after}} = Exports.request_export(user)
      assert retry_after > 0 and retry_after <= Exports.rate_window_seconds()

      # Still only one export row and one job.
      assert Repo.aggregate(from(e in Export, where: e.user_id == ^user.id), :count) == 1
    end

    test "after the window passes, a new request replaces the old export" do
      user = insert_verified_user()

      {:ok, old} = Exports.request_export(user)
      backdate(old, Exports.rate_window_seconds() + 1)

      assert {:ok, new} = Exports.request_export(user)
      assert new.id != old.id
      refute Repo.get(Export, old.id)
    end

    test "one user's requests do not consume another user's allowance" do
      a = insert_verified_user()
      b = insert_verified_user()

      assert {:ok, _} = Exports.request_export(a)
      assert {:ok, _} = Exports.request_export(b)
    end
  end

  # Seed one account with every kind of owned data, including a real encrypted
  # secret, and a second account whose data must never bleed in.
  defp seed_account do
    # No starter agent (ADR 0038): every assertion below names the rows this
    # function seeded, and an agent verification handed out is not one of them.
    user = insert_user_without_agents()

    env = insert_env(user_id: user.id, name: "export-env")
    insert_secret(env, %{"key" => "EXPORT_TOKEN", "value" => @secret_value})

    vault = insert_vault(user_id: user.id, name: "export-vault")
    insert_vault_secret(vault, %{"key" => "VAULT_TOKEN", "value" => @secret_value})

    agent = insert_agent(user_id: user.id, name: "export-agent")
    conv = insert_conversation(user_id: user.id, agent: agent, title: "export conversation")
    turn = insert_turn(conv, prompt: "please export me")
    insert_log_event(conv, turn_id: turn.id, data: "log line from the sprite")

    {:ok, _} =
      Audit.record(%{
        user_id: user.id,
        action: "agent.created",
        resource_type: "agent",
        resource_id: agent.id,
        actor: "ui"
      })

    other = insert_verified_user()
    insert_agent(user_id: other.id, name: "other-tenant-agent")
    other_conv = insert_conversation(user_id: other.id)
    insert_log_event(other_conv, data: "other tenant log line")

    %{user: user, env: env, vault: vault, agent: agent, conv: conv, other: other}
  end

  describe "build/1 and the worker" do
    test "the export contains everything the account owns" do
      %{user: user, conv: conv} = seed_account()

      {:ok, export} = Exports.request_export(user)
      assert :ok = perform_job(AccountExport, %{export_id: export.id, user_id: user.id})

      export = Repo.get!(Export, export.id)
      assert export.status == "completed"
      assert %DateTime{} = export.expires_at
      assert export.byte_size > 0

      doc = export.payload |> :zlib.gunzip() |> Jason.decode!()

      assert doc["account"]["email"] == user.email
      assert [%{"name" => "export-agent"}] = doc["agents"]

      assert [env_doc] = doc["environments"]
      assert env_doc["name"] == "export-env"
      assert env_doc["secret_keys"] == ["EXPORT_TOKEN"]

      assert [vault_doc] = doc["vaults"]
      assert vault_doc["secret_keys"] == ["VAULT_TOKEN"]

      assert [conv_doc] = doc["conversations"]
      assert conv_doc["id"] == conv.id
      assert [%{"prompt" => "please export me"}] = conv_doc["turns"]
      assert [%{"data" => "log line from the sprite"}] = conv_doc["log_events"]

      actions = Enum.map(doc["audit_trail"], & &1["action"])
      assert "agent.created" in actions
      assert "account.export_requested" in actions
    end

    test "secret values never appear in the export — names only" do
      %{user: user} = seed_account()

      {:ok, export} = Exports.request_export(user)
      assert :ok = perform_job(AccountExport, %{export_id: export.id, user_id: user.id})

      json = Repo.get!(Export, export.id).payload |> :zlib.gunzip()

      # The plaintext round-trips through real envelope encryption in the
      # fixture, so this catches any path that decrypts on the way out.
      refute json =~ @secret_value

      # The names are the only trace, plus the UI-facing note saying so.
      doc = Jason.decode!(json)
      assert doc["notes"]["secrets"] =~ "write-only"
    end

    test "the export never contains another tenant's data" do
      %{user: user} = seed_account()

      doc = Exports.build(user.id)
      json = Jason.encode!(doc)

      refute json =~ "other-tenant-agent"
      refute json =~ "other tenant log line"
    end

    test "a superseded or deleted export id is a no-op, not a crash loop" do
      user = insert_verified_user()

      assert :ok =
               perform_job(AccountExport, %{export_id: Ecto.UUID.generate(), user_id: user.id})
    end

    test "completion broadcasts so the account page updates" do
      user = insert_verified_user()
      Phoenix.PubSub.subscribe(Fountain.PubSub, Exports.topic(user.id))

      {:ok, export} = Exports.request_export(user)
      assert :ok = perform_job(AccountExport, %{export_id: export.id, user_id: user.id})

      assert_receive {:export_updated, _}
    end
  end

  describe "get_downloadable_export/2" do
    setup do
      %{user: user} = seed_account()
      {:ok, export} = Exports.request_export(user)
      :ok = perform_job(AccountExport, %{export_id: export.id, user_id: user.id})
      %{user: user, export: Repo.get!(Export, export.id)}
    end

    test "the owner can fetch it", %{user: user, export: export} do
      assert {:ok, %Export{payload: payload}} =
               Exports.get_downloadable_export(export.id, user.id)

      assert is_binary(payload)
    end

    test "another tenant cannot fetch the artifact", %{export: export} do
      other = insert_verified_user()
      assert {:error, :not_found} = Exports.get_downloadable_export(export.id, other.id)
    end

    test "an expired export is not downloadable", %{user: user, export: export} do
      {1, _} =
        Repo.update_all(
          from(e in Export, where: e.id == ^export.id),
          set: [expires_at: DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)]
        )

      assert {:error, :not_found} = Exports.get_downloadable_export(export.id, user.id)
    end

    test "a pending export is not downloadable", %{user: user} do
      pending =
        %Export{}
        |> Export.changeset(%{status: "pending", user_id: user.id})
        |> Repo.insert!()

      assert {:error, :not_found} = Exports.get_downloadable_export(pending.id, user.id)
    end
  end

  describe "purge_expired/0" do
    test "removes expired exports and keeps live ones" do
      %{user: user} = seed_account()
      {:ok, export} = Exports.request_export(user)
      :ok = perform_job(AccountExport, %{export_id: export.id, user_id: user.id})

      other = insert_verified_user()

      expired =
        %Export{}
        |> Export.changeset(%{
          status: "completed",
          user_id: other.id,
          payload: <<1>>,
          expires_at: DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
        })
        |> Repo.insert!()

      assert Exports.purge_expired() == 1
      refute Repo.get(Export, expired.id)
      assert Repo.get(Export, export.id)
    end
  end
end
