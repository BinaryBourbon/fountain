defmodule Fountain.OAuthClientsTest do
  @moduledoc """
  Tenant-registered OAuth clients (#1125): the registry, the development-mode
  boundary that makes a self-chosen redirect URI safe, and the origin lookup
  the CORS plug asks.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Audit
  alias Fountain.OAuth
  alias Fountain.OAuth.Client

  defp pkce_challenge do
    Base.url_encode64(:crypto.hash(:sha256, "verifier"), padding: false)
  end

  defp request(client_id, redirect, over \\ %{}) do
    Map.merge(
      %{
        "client_id" => client_id,
        "redirect_uri" => redirect,
        "code_challenge" => pkce_challenge(),
        "code_challenge_method" => "S256"
      },
      over
    )
  end

  describe "create_client/3" do
    test "generates a client_id and never takes one from the caller" do
      user = insert_verified_user()

      {:ok, client} =
        OAuth.create_client(user.id, %{
          "name" => "Notes",
          "redirect_uris" => ["https://notes.test/callback"],
          "client_id" => "fountain-team"
        })

      assert client.client_id != "fountain-team"
      assert String.starts_with?(client.client_id, "app_")
      assert client.user_id == user.id
    end

    test "starts unpublished, whatever the caller says" do
      user = insert_verified_user()

      {:ok, client} =
        OAuth.create_client(user.id, %{
          "name" => "Notes",
          "redirect_uris" => ["https://notes.test/callback"],
          "published" => true
        })

      refute client.published
    end

    test "derives the origin keys, dropping the port only on loopback" do
      user = insert_verified_user()

      {:ok, client} =
        OAuth.create_client(user.id, %{
          "name" => "Notes",
          "redirect_uris" => [
            "https://notes.test/callback",
            "https://notes.test:8443/other",
            "http://localhost:5173/callback"
          ]
        })

      assert Enum.sort(client.origin_keys) ==
               Enum.sort(["https://notes.test", "https://notes.test:8443", "http://localhost"])
    end

    test "refuses a registration that could never complete a flow" do
      user = insert_verified_user()

      assert {:error, cs} = OAuth.create_client(user.id, %{"name" => "Notes"})
      assert "add at least one redirect URI" in errors_on(cs).redirect_uris
    end

    test "refuses plaintext http off loopback, a fragment, and a bare path" do
      user = insert_verified_user()

      for uri <- ["http://notes.test/callback", "https://notes.test/cb#frag", "/callback"] do
        assert {:error, cs} =
                 OAuth.create_client(user.id, %{"name" => "Notes", "redirect_uris" => [uri]})

        assert errors_on(cs).redirect_uris != []
      end
    end

    test "takes http on loopback, which is the local dev loop" do
      user = insert_verified_user()

      assert {:ok, _} =
               OAuth.create_client(user.id, %{
                 "name" => "Notes",
                 "redirect_uris" => ["http://127.0.0.1:5173/callback"]
               })
    end

    test "records oauth_client.created with the client_id and the URIs" do
      user = insert_verified_user()

      {:ok, client} =
        OAuth.create_client(user.id, %{"name" => "N", "redirect_uris" => ["https://n.test/c"]})

      assert [event] =
               user.id
               |> Audit.list_recent_for_user(20)
               |> Enum.filter(&(&1.action == "oauth_client.created"))

      assert event.resource_type == "oauth_client"
      assert event.resource_id == client.id
      assert event.metadata["client_id"] == client.client_id
      assert event.metadata["redirect_uris"] == ["https://n.test/c"]
    end
  end

  describe "update_client/3" do
    test "renames and re-derives the origin keys" do
      client = insert_oauth_client(redirect_uris: ["https://old.test/c"])

      {:ok, updated} =
        OAuth.update_client(client, %{
          "name" => "New",
          "redirect_uris" => ["https://new.test/c"]
        })

      assert updated.name == "New"
      assert updated.origin_keys == ["https://new.test"]
      assert updated.client_id == client.client_id
    end

    test "cannot publish itself or change owner" do
      other = insert_verified_user()
      client = insert_oauth_client()

      {:ok, updated} =
        OAuth.update_client(client, %{"published" => true, "user_id" => other.id})

      refute updated.published
      assert updated.user_id == client.user_id
    end
  end

  describe "get_client/1" do
    test "config wins, so a row can never shadow a first-party client" do
      assert %{id: "test-app", published: true, owner_id: nil} = OAuth.get_client("test-app")
    end

    test "returns a row as an unpublished client owned by its registrant" do
      client = insert_oauth_client()

      assert %{id: id, published: false, owner_id: owner, record_id: record_id} =
               OAuth.get_client(client.client_id)

      assert id == client.client_id
      assert owner == client.user_id
      assert record_id == client.id
    end

    test "is nil for an id nobody registered" do
      refute OAuth.get_client("app_nope")
      refute OAuth.get_client(nil)
    end
  end

  describe "validate_request/2 — development mode" do
    test "the owner may sign in to their own unpublished client" do
      client = insert_oauth_client(redirect_uris: ["https://mine.test/c"])

      assert {:ok, %{id: _}} =
               OAuth.validate_request(
                 request(client.client_id, "https://mine.test/c"),
                 client.user_id
               )
    end

    test "anyone else is refused, and told nothing about the redirect URI" do
      stranger = insert_verified_user()
      client = insert_oauth_client(redirect_uris: ["https://mine.test/c"])

      assert {:error, :development_mode} =
               OAuth.validate_request(
                 request(client.client_id, "https://mine.test/c"),
                 stranger.id
               )

      # A wrong redirect from a stranger is still development_mode: the
      # identity gate answers first so the error page leaks no registration.
      assert {:error, :development_mode} =
               OAuth.validate_request(
                 request(client.client_id, "https://evil.test/c"),
                 stranger.id
               )
    end

    test "fails closed when there is no signed-in user" do
      client = insert_oauth_client(redirect_uris: ["https://mine.test/c"])

      assert {:error, :development_mode} =
               OAuth.validate_request(request(client.client_id, "https://mine.test/c"))
    end

    test "a published client takes any account" do
      stranger = insert_verified_user()
      client = insert_oauth_client(redirect_uris: ["https://mine.test/c"], published: true)

      assert {:ok, _} =
               OAuth.validate_request(
                 request(client.client_id, "https://mine.test/c"),
                 stranger.id
               )
    end

    test "the owner still gets an exact redirect check" do
      client = insert_oauth_client(redirect_uris: ["https://mine.test/c"])

      assert {:error, :redirect_uri_mismatch} =
               OAuth.validate_request(
                 request(client.client_id, "https://mine.test/other"),
                 client.user_id
               )
    end
  end

  describe "validate_request/2 — loopback ports" do
    test "an unpublished loopback redirect matches on any port" do
      client = insert_oauth_client(redirect_uris: ["http://localhost:5173/callback"])

      assert {:ok, _} =
               OAuth.validate_request(
                 request(client.client_id, "http://localhost:5174/callback"),
                 client.user_id
               )
    end

    test "but not on another path, host or scheme" do
      client = insert_oauth_client(redirect_uris: ["http://localhost:5173/callback"])

      for uri <- [
            "http://localhost:5174/other",
            "http://evil.test:5174/callback",
            "https://localhost:5174/callback"
          ] do
        assert {:error, :redirect_uri_mismatch} =
                 OAuth.validate_request(request(client.client_id, uri), client.user_id)
      end
    end

    test "a published client gets no port latitude" do
      client =
        insert_oauth_client(redirect_uris: ["http://localhost:5173/callback"], published: true)

      assert {:error, :redirect_uri_mismatch} =
               OAuth.validate_request(
                 request(client.client_id, "http://localhost:5174/callback"),
                 client.user_id
               )
    end
  end

  describe "form_action_origins/1" do
    test "is the origin of the redirect the browser will actually be sent to" do
      assert OAuth.form_action_origins("https://mine.test/callback") == ["https://mine.test"]
      assert OAuth.form_action_origins("https://mine.test:8443/cb") == ["https://mine.test:8443"]
    end

    # The registered URI is the wrong source: a loopback client registered
    # against :5199 and legally asked for :5200 would get a header naming
    # :5199, and Chrome would block a redirect the server had approved.
    test "follows the requested port, not the registered one" do
      assert OAuth.form_action_origins("http://localhost:5200/callback") ==
               ["http://localhost:5200"]
    end

    test "is empty for something with no origin" do
      assert OAuth.form_action_origins("/callback") == []
    end
  end

  describe "registered_origin?/1" do
    test "true for an origin a registered client redirects to" do
      insert_oauth_client(redirect_uris: ["https://notes.test/callback"])

      assert OAuth.registered_origin?("https://notes.test")
      refute OAuth.registered_origin?("https://evil.test")
    end

    test "matches a loopback origin on any port" do
      insert_oauth_client(redirect_uris: ["http://localhost:5173/callback"])

      assert OAuth.registered_origin?("http://localhost:5173")
      assert OAuth.registered_origin?("http://localhost:9999")
      refute OAuth.registered_origin?("https://localhost:5173")
    end

    test "covers the config clients too, so OAUTH_CLIENTS need not be mirrored" do
      assert OAuth.registered_origin?("https://app.test")
    end

    test "is false for junk" do
      refute OAuth.registered_origin?("not-an-origin")
      refute OAuth.registered_origin?(nil)
    end
  end

  describe "list_clients/1 and get_client_record/2" do
    test "are scoped to the tenant" do
      mine = insert_oauth_client()
      theirs = insert_oauth_client()

      assert [found] = OAuth.list_clients(mine.user_id)
      assert found.id == mine.id

      assert OAuth.get_client_record(mine.id, mine.user_id)
      refute OAuth.get_client_record(theirs.id, mine.user_id)
    end
  end

  describe "delete_client/2" do
    test "stops new sign-ins through the client" do
      client = insert_oauth_client()

      {:ok, _} = OAuth.delete_client(client)

      refute OAuth.get_client(client.client_id)
    end
  end

  describe "Client.origin_key/1" do
    test "keeps the port off loopback and drops it on" do
      assert Client.origin_key("https://a.test:8443") == "https://a.test:8443"
      assert Client.origin_key("https://a.test") == "https://a.test"
      assert Client.origin_key("http://localhost:5173") == "http://localhost"
      assert Client.origin_key("http://127.0.0.1:5173") == "http://127.0.0.1"
    end
  end
end
