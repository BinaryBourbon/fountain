defmodule FountainWeb.SecretFormsLiveTest do
  use FountainWeb.ConnCase, async: true

  import Mimic
  import Phoenix.LiveViewTest

  alias Fountain.{Crypto, Environments, Vaults}

  # Regression tests for #391: the environment and vault forms used to unwrap
  # the tenant DEK at mount and hold it in socket assigns for the life of the
  # LiveView. LiveView crash reports dump the channel state — assigns included —
  # to the logger and to Sentry, so any unhandled exception leaked the key that
  # decrypts the tenant's entire secret set (plus whatever secret was being
  # typed, via the :new_secret assign refreshed on every phx-change).

  setup %{conn: conn} do
    user = insert_verified_user()
    {:ok, conn: login_user(conn, user), user: user}
  end

  # The DEK is 32 random bytes, so a byte-level scan of the serialized process
  # state cannot false-positive. :sys.get_state reaches the LiveView channel
  # process — the same state OTP would put in a crash report.
  defp refute_in_state(view, bytes) do
    state_bin = view.pid |> :sys.get_state() |> :erlang.term_to_binary()
    assert :binary.match(state_bin, bytes) == :nomatch
  end

  describe "EnvironmentsLive.Form secrets (#391)" do
    setup %{user: user} do
      {:ok, env: insert_env(user_id: user.id)}
    end

    test "never holds the tenant DEK or plaintext secret in process state",
         %{conn: conn, user: user, env: env} do
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      value = "plaintext-sentinel-2b0c9e41"

      {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}/edit")
      refute_in_state(view, dek)

      html =
        render_submit(view, "add_secret", %{"secret" => %{"key" => "TOKEN", "value" => value}})

      assert html =~ "Secret saved"
      refute_in_state(view, dek)
      refute_in_state(view, value)
    end

    test "add_secret persists through the handler-scoped DEK and resets the form",
         %{conn: conn, user: user, env: env} do
      {:ok, view, html} = live(conn, ~p"/environments/#{env.id}/edit")
      assert html =~ "env-secret-form-0"

      html =
        render_submit(view, "add_secret", %{"secret" => %{"key" => "TOKEN", "value" => "v1"}})

      assert html =~ "TOKEN"
      # The versioned form id is the reset mechanism for the uncontrolled
      # inputs — a stale id means the fields keep the submitted plaintext.
      assert html =~ "env-secret-form-1"

      {:ok, dek} = Crypto.load_tenant_key(user.id)
      assert Environments.decrypted_env(env, dek) == %{"TOKEN" => "v1"}
    end

    test "add_secret flashes instead of crashing when the tenant key cannot be loaded",
         %{conn: conn, env: env} do
      {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}/edit")

      stub(Fountain.Crypto, :load_tenant_key, fn _user_id -> {:error, :unwrap_failed} end)

      html = render_submit(view, "add_secret", %{"secret" => %{"key" => "TOKEN", "value" => "v"}})

      assert html =~ "Could not load encryption key"
      assert Process.alive?(view.pid)
    end

    test "mounts without touching the tenant key at all", %{conn: conn, env: env} do
      # Pre-#391 mount did `{:ok, dek} = Crypto.load_tenant_key(user_id)`,
      # so an unwrap failure was a MatchError before first render.
      stub(Fountain.Crypto, :load_tenant_key, fn _user_id -> {:error, :unwrap_failed} end)

      assert {:ok, _view, _html} = live(conn, ~p"/environments/#{env.id}/edit")
    end
  end

  describe "VaultsLive.Form secrets (#391)" do
    setup %{user: user} do
      {:ok, vault: insert_vault(user_id: user.id)}
    end

    test "never holds the tenant DEK or plaintext secret in process state",
         %{conn: conn, user: user, vault: vault} do
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      value = "plaintext-sentinel-7d4a1f83"

      {:ok, view, _html} = live(conn, ~p"/vaults/#{vault.id}/edit")
      refute_in_state(view, dek)

      html =
        render_submit(view, "add_secret", %{"secret" => %{"key" => "TOKEN", "value" => value}})

      assert html =~ "Secret saved"
      refute_in_state(view, dek)
      refute_in_state(view, value)
    end

    test "add_secret persists through the handler-scoped DEK and resets the form",
         %{conn: conn, user: user, vault: vault} do
      {:ok, view, html} = live(conn, ~p"/vaults/#{vault.id}/edit")
      assert html =~ "vault-secret-form-0"

      html =
        render_submit(view, "add_secret", %{"secret" => %{"key" => "TOKEN", "value" => "v1"}})

      assert html =~ "TOKEN"
      assert html =~ "vault-secret-form-1"

      {:ok, dek} = Crypto.load_tenant_key(user.id)
      assert Vaults.decrypted_env(vault, dek) == %{"TOKEN" => "v1"}
    end

    test "add_secret flashes instead of crashing when the tenant key cannot be loaded",
         %{conn: conn, vault: vault} do
      {:ok, view, _html} = live(conn, ~p"/vaults/#{vault.id}/edit")

      stub(Fountain.Crypto, :load_tenant_key, fn _user_id -> {:error, :unwrap_failed} end)

      html = render_submit(view, "add_secret", %{"secret" => %{"key" => "TOKEN", "value" => "v"}})

      assert html =~ "Could not load encryption key"
      assert Process.alive?(view.pid)
    end

    test "mounts without touching the tenant key at all", %{conn: conn, vault: vault} do
      stub(Fountain.Crypto, :load_tenant_key, fn _user_id -> {:error, :unwrap_failed} end)

      assert {:ok, _view, _html} = live(conn, ~p"/vaults/#{vault.id}/edit")
    end
  end
end
