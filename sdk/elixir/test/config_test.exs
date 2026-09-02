defmodule Fountain.ConfigTest do
  use ExUnit.Case, async: true
  alias Fountain.Config

  test "parses profiles and resolves explicit values before environment" do
    raw = """
    [default]
    api_key = ignored
    [work]
    api_key = "from-file"
    base_url = https://file.example/
    """

    path =
      Path.join(System.tmp_dir!(), "fountain-credentials-#{System.unique_integer([:positive])}")

    File.write!(path, raw)
    env = fn key -> %{"FOUNTAIN_PROFILE" => "work", "FOUNTAIN_API_KEY" => "from-env"}[key] end
    config = Config.resolve(api_key: "explicit", credentials_file: path, env: env)
    assert config.api_key == "explicit"
    assert config.base_url == "https://file.example"
    assert Config.parse_credentials(raw, "work")["api_key"] == "from-file"
    File.rm!(path)
  end

  test "builds UI and API fallback conversation URLs" do
    config = %Config{base_url: "https://api", api_key: "x", app_url: "https://app"}
    assert Config.conversation_url("abc", config) == "https://app/#/c/abc"

    assert Config.conversation_url("abc", %{config | app_url: ""}) ==
             "https://api/api/conversations/abc"
  end
end
