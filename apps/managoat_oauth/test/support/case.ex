defmodule Managoat.OAuth.Case do
  @moduledoc """
  A test on the library's own database: one SQL-sandbox connection per test,
  the request fixtures the state machine tests share, and the recording host
  reset so a dial turned in one test never leaks into the next one that
  reuses the process.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Managoat.OAuth.Case

      alias Managoat.OAuth.{AuthorizationCode, DeviceGrant, TestInstance, TestRepo}
      alias Managoat.OAuth.Host.Recording
    end
  end

  setup tags do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Managoat.OAuth.TestRepo, shared: not tags[:async])

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Managoat.OAuth.Host.Recording.reset()
    :ok
  end

  @client "test-app"
  @redirect "https://app.test/callback"

  @doc "The client id every request fixture names."
  def client, do: @client

  @doc "The redirect URI every request fixture names."
  def redirect, do: @redirect

  @doc "A fresh PKCE pair: `{verifier, challenge}`."
  def pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {verifier, Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)}
  end

  @doc "An authorization request for `challenge`, with `over` merged on top."
  def request(challenge, over \\ %{}) do
    Map.merge(
      %{
        "client_id" => @client,
        "redirect_uri" => @redirect,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      },
      over
    )
  end

  @doc "A token request for `code` and `verifier`, with `over` merged on top."
  def token_request(code, verifier, over \\ %{}) do
    Map.merge(
      %{
        "code" => code,
        "code_verifier" => verifier,
        "client_id" => @client,
        "redirect_uri" => @redirect
      },
      over
    )
  end

  @doc "An opaque subject the way a host would hand one over."
  def subject, do: Ecto.UUID.generate()
end
