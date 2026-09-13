defmodule FountainWeb.ApiKeysLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  test "the owner can revoke a claimed principal from the console", %{conn: conn} do
    owner = insert_verified_user()
    app = insert_verified_user()

    {:ok, opened} =
      Fountain.Principals.create_claimable(app, %{"application_id" => "console-test"})

    {:ok, claimed} = Fountain.Principals.claim(opened.claimable.id, opened.claim_token, owner)
    {:ok, _, key} = Accounts.authenticate_api_key(claimed.api_key)
    {:ok, view, html} = conn |> login_user(owner) |> live(~p"/api-keys")
    assert html =~ "principal:console-test"
    assert html =~ "Principal"
    view |> element("button[phx-click=revoke][phx-value-id='#{key.id}']") |> render_click()
    assert {:error, :revoked} = Accounts.authenticate_api_key(claimed.api_key)
    refute render(view) =~ "principal:console-test"
  end

  test "owners can replace revoked principal keys and see the new secret once", %{conn: conn} do
    owner = insert_verified_user()
    app = insert_verified_user()

    {:ok, opened} =
      Fountain.Principals.create_claimable(app, %{"application_id" => "renew-console"})

    {:ok, claimed} = Fountain.Principals.claim(opened.claimable.id, opened.claim_token, owner)
    {:ok, _, key} = Accounts.authenticate_api_key(claimed.api_key)
    {:ok, _} = Accounts.revoke_managed_api_key(owner.id, key.id)
    {:ok, view, _html} = conn |> login_user(owner) |> live(~p"/api-keys")

    assert has_element?(
             view,
             "#renew-principal-key option[value='#{claimed.claimable.user_id}']",
             "renew-console (#{claimed.claimable.user_id})"
           )

    assert has_element?(
             view,
             ~s(#renew-principal-key[phx-hook="ConfirmSubmit"][data-confirm="Replace this principal's key? Its current key will stop working."])
           )

    view
    |> form("#renew-principal-key", principal_id: claimed.claimable.user_id)
    |> render_submit()

    raw =
      view
      |> element("#new-api-key")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

    assert {:ok, principal, new_key} = Accounts.authenticate_api_key(raw)
    assert principal.id == claimed.claimable.user_id
    assert new_key.scopes == ["principal"]
    assert render(view) =~ new_key.key_prefix
    view |> element("button[phx-click=dismiss_new_key]") |> render_click()
    refute render(view) =~ raw

    view |> form("#renew-principal-key", principal_id: principal.id) |> render_submit()
    assert {:error, :revoked} = Accounts.authenticate_api_key(raw)
  end

  test "principal renewal rejects forged ownership and malformed ids", %{conn: conn} do
    owner = insert_verified_user()
    app = insert_verified_user()
    {:ok, opened} = Fountain.Principals.create_claimable(app, %{"application_id" => "foreign"})
    {:ok, claimed} = Fountain.Principals.claim(opened.claimable.id, opened.claim_token, owner)
    {:ok, view, _html} = conn |> login_user(app) |> live(~p"/api-keys")
    refute has_element?(view, "#renew-principal-key")

    for id <- [claimed.claimable.user_id, "not-a-uuid"] do
      html = render_submit(view, "renew_principal_key", %{"principal_id" => id})
      assert html =~ "Could not replace principal key"
      refute html =~ claimed.api_key
    end

    assert {:ok, _, _} = Accounts.authenticate_api_key(claimed.api_key)
  end

  test "principal picker keeps unnamed owned principals and excludes another owner's names", %{
    conn: conn
  } do
    owner = insert_verified_user()
    other_owner = insert_verified_user()
    app = insert_verified_user()
    {:ok, principal} = Accounts.create_principal_user()

    %Fountain.Principals.Owner{}
    |> Fountain.Principals.Owner.changeset(%{
      owner_user_id: owner.id,
      principal_user_id: principal.id
    })
    |> Fountain.Repo.insert!()

    {:ok, opened} =
      Fountain.Principals.create_claimable(app, %{"application_id" => "another-owners-app"})

    {:ok, claimed} =
      Fountain.Principals.claim(opened.claimable.id, opened.claim_token, other_owner)

    {:ok, view, html} = conn |> login_user(owner) |> live(~p"/api-keys")

    label =
      view
      |> element("#renew-principal-key option[value='#{principal.id}']")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

    assert label == principal.id

    refute has_element?(view, "#renew-principal-key option[value='#{claimed.claimable.user_id}']")
    refute html =~ "another-owners-app"
    assert Fountain.Principals.list_owned(owner.id) == [principal.id]
  end

  describe "ApiKeysLive.Index — rendering" do
    test "shows existing active keys", %{conn: conn} do
      user = insert_verified_user()
      insert_api_key(user, "ci-deploy")

      conn = login_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/api-keys")

      assert html =~ "ci-deploy"
      assert html =~ "ftn_"
    end

    test "renders key with nil last_used_at using em-dash placeholder", %{conn: conn} do
      user = insert_verified_user()
      insert_api_key(user, "never-used")

      conn = login_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/api-keys")

      # Key exists, page renders without error; last_used_at is nil so "—" appears
      assert html =~ "never-used"
      assert html =~ "—"
    end

    test "shows empty state when no keys exist", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/api-keys")

      assert html =~ "No API keys yet"
    end

    test "unauthenticated user is redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/api-keys")
      assert path =~ "/auth/login"
    end
  end

  describe "ApiKeysLive.Index — create_key" do
    test "creates a key and shows raw token once", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/api-keys")

      html =
        lv
        |> form("form[phx-submit='create_key']", label: "my-key")
        |> render_submit()

      assert html =~ "ftn_"
      assert html =~ "Copy"
      assert html =~ "it won&#39;t be shown again" or html =~ "won't be shown again"
    end

    test "dismissing the new key banner hides the raw token", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/api-keys")

      lv |> form("form[phx-submit='create_key']", label: "temp-key") |> render_submit()

      html = lv |> element("button", "I've copied it") |> render_click()
      refute html =~ "ftn_" and html =~ "won't be shown again"
    end
  end

  describe "ApiKeysLive.Index — revoke" do
    test "revoking a key removes it from the list", %{conn: conn} do
      user = insert_verified_user()
      {key, _raw} = insert_api_key(user, "to-revoke")

      conn = login_user(conn, user)
      {:ok, lv, html} = live(conn, ~p"/api-keys")
      assert html =~ "to-revoke"

      lv |> element("button[phx-value-id='#{key.id}']", "Revoke") |> render_click()

      html = render(lv)
      refute html =~ "to-revoke"
    end

    test "cannot revoke another user's key", %{conn: conn} do
      owner = insert_verified_user()
      attacker = insert_verified_user()
      {owner_key, _} = insert_api_key(owner, "owner-key")

      # Try via context directly — LiveView won't even show other user's keys
      assert {:error, :not_found} = Accounts.revoke_api_key(attacker.id, owner_key.id)
    end

    test "revoking a non-existent key shows an error flash", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/api-keys")

      # Send a revoke event with a UUID that doesn't exist for this user
      render_click(lv, "revoke", %{"id" => Ecto.UUID.generate()})

      html = render(lv)
      assert html =~ "Key not found"
    end
  end
end

# Accounts.create_api_key stub must be visible to the LiveView process, so
# this uses Mimic global mode in a separate non-async module.
defmodule FountainWeb.ApiKeysLiveErrorTest do
  use FountainWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  setup :set_mimic_global

  describe "ApiKeysLive.Index — create_key error path" do
    test "create_key shows flash error when Accounts.create_api_key returns error", %{conn: conn} do
      user = insert_verified_user()

      # Arity 3: the LiveView passes `Audited.attribution/1` through so the
      # context can attribute the mint it audits (#542).
      stub(Accounts, :create_api_key, fn _user_id, _label, _opts ->
        cs =
          %Fountain.Accounts.ApiKey{}
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.add_error(:name, "is invalid")

        {:error, cs}
      end)

      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/api-keys")

      render_submit(lv |> element("form[phx-submit='create_key']"), %{label: "bad-key"})

      html = render(lv)
      assert html =~ "Failed to create API key"
    end
  end
end
