defmodule Fountain.Connections.PlatformScopeOverrideTest do
  # Writes global app env (the operator scope override), so never async —
  # and in its own file, per the async-global-config guardrail.
  use ExUnit.Case, async: false

  alias Fountain.Connections.Platform

  test "an operator's scope list replaces the default, per provider" do
    Application.put_env(:fountain, :microsoft_oauth_scopes, ~w(openid offline_access Mail.Send))
    on_exit(fn -> Application.delete_env(:fountain, :microsoft_oauth_scopes) end)

    assert Platform.get("microsoft").scopes == ~w(openid offline_access Mail.Send)
    # the others keep their defaults
    assert "https://www.googleapis.com/auth/gmail.modify" in Platform.get("google").scopes
  end
end
