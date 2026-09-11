defmodule Fountain.OAuth.ClientTest do
  @moduledoc """
  The row a tenant registers an OAuth client into (#1125), on its own, before
  any context reads it: what a redirect URI may be, and what origin key the
  CORS lookup will later ask for.
  """
  use Fountain.DataCase, async: true

  alias Fountain.OAuth.Client
  alias Fountain.Repo

  defp insert(attrs, user_id) do
    %Client{} |> Client.changeset(attrs, user_id) |> Repo.insert()
  end

  describe "changeset/3" do
    test "generates a client_id and never takes one from the caller" do
      user = insert_verified_user()

      {:ok, client} =
        insert(
          %{
            "name" => "Notes",
            "redirect_uris" => ["https://notes.test/callback"],
            "client_id" => "fountain-team"
          },
          user.id
        )

      assert client.client_id != "fountain-team"
      assert String.starts_with?(client.client_id, "app_")
      assert client.user_id == user.id
    end

    test "starts unpublished, whatever the caller says" do
      user = insert_verified_user()

      {:ok, client} =
        insert(
          %{
            "name" => "Notes",
            "redirect_uris" => ["https://notes.test/callback"],
            "published" => true
          },
          user.id
        )

      refute client.published
    end

    test "never casts the owner from caller attributes" do
      owner = insert_verified_user()
      other = insert_verified_user()

      {:ok, client} =
        insert(
          %{
            "name" => "Notes",
            "redirect_uris" => ["https://notes.test/callback"],
            "user_id" => other.id
          },
          owner.id
        )

      assert client.user_id == owner.id
    end

    test "refuses a registration that could never complete a flow" do
      user = insert_verified_user()

      assert {:error, cs} = insert(%{"name" => "Notes"}, user.id)
      assert "add at least one redirect URI" in errors_on(cs).redirect_uris
    end

    test "caps how many redirect URIs one client may carry" do
      user = insert_verified_user()
      uris = for n <- 1..11, do: "https://notes.test/cb#{n}"

      assert {:error, cs} = insert(%{"name" => "Notes", "redirect_uris" => uris}, user.id)
      assert "at most 10 redirect URIs" in errors_on(cs).redirect_uris
    end

    test "refuses plaintext http off loopback, a fragment, and a bare path" do
      user = insert_verified_user()

      for uri <- ["http://notes.test/callback", "https://notes.test/cb#frag", "/callback"] do
        assert {:error, cs} = insert(%{"name" => "Notes", "redirect_uris" => [uri]}, user.id)
        assert errors_on(cs).redirect_uris != []
      end
    end

    test "takes http on loopback, which is the local dev loop" do
      user = insert_verified_user()

      assert {:ok, _} =
               insert(%{"name" => "N", "redirect_uris" => ["http://127.0.0.1:5173/cb"]}, user.id)
    end

    test "derives the origin keys, dropping the port only on loopback" do
      user = insert_verified_user()

      {:ok, client} =
        insert(
          %{
            "name" => "Notes",
            "redirect_uris" => [
              "https://notes.test/callback",
              "https://notes.test:8443/other",
              "http://localhost:5173/callback"
            ]
          },
          user.id
        )

      assert Enum.sort(client.origin_keys) ==
               Enum.sort(["https://notes.test", "https://notes.test:8443", "http://localhost"])
    end

    # The cap counts what will be stored. Eleven copies of one URI is one URI.
    test "deduplicates before it counts, so repeats do not hit the cap" do
      user = insert_verified_user()
      uris = for _ <- 1..11, do: "https://notes.test/callback"

      assert {:ok, client} = insert(%{"name" => "Notes", "redirect_uris" => uris}, user.id)
      assert client.redirect_uris == ["https://notes.test/callback"]
    end

    test "reports a repeated bad URI once, not once per copy" do
      user = insert_verified_user()

      assert {:error, cs} =
               insert(
                 %{
                   "name" => "Notes",
                   "redirect_uris" => ["http://notes.test/cb", "http://notes.test/cb"]
                 },
                 user.id
               )

      assert length(errors_on(cs).redirect_uris) == 1
    end

    test "keeps the same redirect URI once" do
      user = insert_verified_user()

      {:ok, client} =
        insert(
          %{"name" => "N", "redirect_uris" => ["https://n.test/cb", "https://n.test/cb"]},
          user.id
        )

      assert client.redirect_uris == ["https://n.test/cb"]
    end
  end

  describe "uri_error/1" do
    test "names the reason, or nothing when the URI is usable" do
      assert Client.uri_error("https://notes.test/callback") == nil
      assert Client.uri_error("http://localhost:5173/callback") == nil
      assert Client.uri_error("ftp://notes.test/cb") =~ "https://"
      assert Client.uri_error("https:///cb") =~ "host"
      assert Client.uri_error("https://notes.test/cb#x") =~ "fragment"
      assert Client.uri_error("https://user:pw@notes.test/cb") =~ "user:password@"
      assert Client.uri_error(" https://notes.test/cb ") =~ "whitespace"
      assert Client.uri_error("https://notes.test/" <> String.duplicate("a", 2001)) =~ "too long"
      assert Client.uri_error(:not_a_string) =~ "string"
    end
  end

  describe "loopback?/1" do
    test "is the developer's own machine and nothing else" do
      assert Client.loopback?("localhost")
      assert Client.loopback?("127.0.0.1")
      assert Client.loopback?("::1")
      assert Client.loopback?("LOCALHOST")
      refute Client.loopback?("notes.test")
      refute Client.loopback?(nil)
    end
  end

  describe "origin_of/1 and origins_of/1" do
    test "keeps a non-default port and drops a default one" do
      assert Client.origin_of("https://a.test/cb") == "https://a.test"
      assert Client.origin_of("https://a.test:443/cb") == "https://a.test"
      assert Client.origin_of("https://a.test:8443/cb") == "https://a.test:8443"
      assert Client.origin_of("http://[::1]:5173/cb") == "http://[::1]:5173"
      assert Client.origin_of("/cb") == nil
      assert Client.origin_of(nil) == nil
    end

    test "collapses several URIs on one origin" do
      assert Client.origins_of(["https://a.test/cb", "https://a.test/other", "/cb"]) ==
               ["https://a.test"]
    end
  end

  describe "origin_key/1" do
    test "keeps the port off loopback and drops it on" do
      assert Client.origin_key("https://a.test:8443") == "https://a.test:8443"
      assert Client.origin_key("https://a.test") == "https://a.test"
      assert Client.origin_key("http://localhost:5173") == "http://localhost"
      assert Client.origin_key("http://127.0.0.1:5173") == "http://127.0.0.1"
      assert Client.origin_key("http://[::1]:5173") == "http://[::1]"
      assert Client.origin_key("not-an-origin") == nil
      assert Client.origin_key(nil) == nil
    end
  end

  describe "generate_client_id/0" do
    test "is random, so two apps with one name do not collide" do
      refute Client.generate_client_id() == Client.generate_client_id()
    end
  end
end
