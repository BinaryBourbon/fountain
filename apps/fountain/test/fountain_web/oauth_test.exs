defmodule FountainWeb.OAuthTest do
  use ExUnit.Case, async: true

  alias FountainWeb.OAuth

  describe "github_configured?/1" do
    test "true for a non-empty client id" do
      assert OAuth.github_configured?(client_id: "Iv1.abc123", client_secret: "s")
    end

    test "false for a nil client id" do
      refute OAuth.github_configured?(client_id: nil)
    end

    test "false for an empty-string client id" do
      refute OAuth.github_configured?(client_id: "")
    end

    test "false when the key is absent or the config is nil" do
      refute OAuth.github_configured?([])
      refute OAuth.github_configured?(nil)
    end
  end

  describe "github_configured?/0" do
    test "reads the ueberauth strategy config (fake id set in config/test.exs)" do
      assert OAuth.github_configured?()
    end
  end
end
