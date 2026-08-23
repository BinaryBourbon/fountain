defmodule Fountain.Workers.SecretExpirySweeperTest do
  use Fountain.DataCase, async: true

  import Swoosh.TestAssertions

  alias Fountain.Repo
  alias Fountain.Vaults
  alias Fountain.Workers.SecretExpirySweeper

  defp expiring(vault, key, days_from_now) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(days_from_now, :day)
      |> DateTime.truncate(:second)

    insert_vault_secret(vault, key: key, expires_at: expires_at)
  end

  defp reloaded(secret), do: Repo.get!(Fountain.Vaults.VaultSecret, secret.id)

  test "emails the owner one mail listing every due secret, and stamps them" do
    user = insert_verified_user()
    vault = insert_vault(user_id: user.id, name: "prod-creds")
    due_a = expiring(vault, "GH_TOKEN", 3)
    due_b = expiring(vault, "NPM_TOKEN", 5)
    not_due = expiring(vault, "FAR_OFF", 60)

    assert :ok = perform_job(SecretExpirySweeper, %{})

    assert_email_sent(fn email ->
      assert email.to == [{user.email, user.email}]
      assert email.subject == "2 of your vault secrets expire soon"
      assert email.text_body =~ "GH_TOKEN"
      assert email.text_body =~ "NPM_TOKEN"
      refute email.text_body =~ "FAR_OFF"
      assert email.text_body =~ "prod-creds"
    end)

    assert reloaded(due_a).expiry_notified_at
    assert reloaded(due_b).expiry_notified_at
    refute reloaded(not_due).expiry_notified_at
  end

  test "an already-expired secret is still worth one notice" do
    user = insert_verified_user()
    vault = insert_vault(user_id: user.id)
    expiring(vault, "DEAD_TOKEN", -2)

    assert :ok = perform_job(SecretExpirySweeper, %{})

    assert_email_sent(fn email ->
      assert email.subject == "Your vault secret DEAD_TOKEN expires soon"
      assert email.text_body =~ "DEAD_TOKEN"
    end)
  end

  test "sends nothing twice: a stamped secret is skipped on the next run" do
    user = insert_verified_user()
    vault = insert_vault(user_id: user.id)
    expiring(vault, "GH_TOKEN", 3)

    assert :ok = perform_job(SecretExpirySweeper, %{})
    # assert_email_sent consumes the first run's delivery from the mailbox,
    # so the second run's silence is observable.
    assert_email_sent()

    assert :ok = perform_job(SecretExpirySweeper, %{})
    assert_no_email_sent()
  end

  test "re-notifies after the expiry is moved, because the changeset clears the stamp" do
    user = insert_verified_user()
    vault = insert_vault(user_id: user.id)
    secret = expiring(vault, "GH_TOKEN", 3)

    assert :ok = perform_job(SecretExpirySweeper, %{})
    assert reloaded(secret).expiry_notified_at

    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

    new_expiry = DateTime.utc_now() |> DateTime.add(4, :day) |> DateTime.truncate(:second)

    {:ok, rotated} =
      Vaults.upsert_secret(
        vault,
        %{"key" => "GH_TOKEN", "value" => "rotated", "expires_at" => new_expiry},
        dek
      )

    refute rotated.expiry_notified_at
  end

  test "skips owners who never verified their email" do
    user = insert_user()
    vault = insert_vault(user_id: user.id)
    secret = expiring(vault, "GH_TOKEN", 3)

    assert :ok = perform_job(SecretExpirySweeper, %{})

    assert_no_email_sent()
    # Not stamped either: verification later gets the notice on the next run.
    refute reloaded(secret).expiry_notified_at
  end

  test "secrets without an expiry are never touched" do
    user = insert_verified_user()
    vault = insert_vault(user_id: user.id)
    insert_vault_secret(vault, key: "NO_EXPIRY")

    assert :ok = perform_job(SecretExpirySweeper, %{})

    assert_no_email_sent()
  end

  test "notice_days 0 disables the sweep" do
    user = insert_verified_user()
    vault = insert_vault(user_id: user.id)
    expiring(vault, "GH_TOKEN", 1)

    Application.put_env(:fountain, :secret_expiry_notice_days, 0)
    on_exit(fn -> Application.delete_env(:fountain, :secret_expiry_notice_days) end)

    assert :ok = perform_job(SecretExpirySweeper, %{})

    assert_no_email_sent()
  end
end
