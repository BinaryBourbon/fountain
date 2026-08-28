defmodule Fountain.RuntimeConfigTest do
  @moduledoc """
  Evaluates `config/runtime.exs` the way the release config provider does.

  The FOUNTAIN_DOMAIN defect lived entirely in this file, so no unit test of
  application code could have caught it: `:public_url` was set to a bare host
  and every consumer faithfully produced schemeless links. These cases pin the
  derivation itself, including the legacy spelling that production still uses.
  """

  # Mutates process env, so it must not run alongside anything else.
  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)

  @required %{
    "PHX_SERVER" => "true",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db",
    # Prod now refuses to boot with no mail delivery configured, so every
    # prod-config evaluation needs one — and a configured provider requires
    # EMAIL_FROM.
    "RESEND_API_KEY" => "re_test_key",
    "EMAIL_FROM" => "noreply@fountain.example.com"
  }

  setup do
    # A valid 32-byte key, or runtime.exs raises before reaching the URL logic.
    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    previous = System.get_env()

    on_exit(fn ->
      System.put_env(previous)

      for k <-
            ~w(PUBLIC_URL PHX_HOST FOUNTAIN_DOMAIN RENDER_EXTERNAL_URL RESEND_API_KEY SMTP_HOST EMAIL_DELIVERY),
          not Map.has_key?(previous, k),
          do: System.delete_env(k)
    end)

    {:ok, base: Map.put(@required, "MASTER_SECRETS_KEY", key)}
  end

  defp read_prod_config(env) do
    for k <- ~w(PUBLIC_URL PHX_HOST FOUNTAIN_DOMAIN RENDER_EXTERNAL_URL SMTP_HOST EMAIL_DELIVERY),
        do: System.delete_env(k)

    System.put_env(env)
    Config.Reader.read!(@runtime_exs, env: :prod)[:fountain]
  end

  test "a bare FOUNTAIN_DOMAIN still yields an absolute :public_url", %{base: base} do
    # This is exactly what production sets today (k8s/deployment.yaml), and it
    # is the case that was producing "fountain.inevitable.fyi/users/confirm/...".
    cfg = read_prod_config(Map.put(base, "FOUNTAIN_DOMAIN", "fountain.example.com"))

    assert cfg[:public_url] == "https://fountain.example.com"
    assert cfg[:phx_host] == "fountain.example.com"
  end

  test "PUBLIC_URL and PHX_HOST are used when set", %{base: base} do
    cfg =
      base
      |> Map.merge(%{
        "PUBLIC_URL" => "https://app.example.com",
        "PHX_HOST" => "internal.example.com"
      })
      |> read_prod_config()

    assert cfg[:public_url] == "https://app.example.com"
    assert cfg[:phx_host] == "internal.example.com"
  end

  test "PUBLIC_URL takes precedence over the legacy FOUNTAIN_DOMAIN", %{base: base} do
    cfg =
      base
      |> Map.merge(%{
        "PUBLIC_URL" => "https://new.example.com",
        "FOUNTAIN_DOMAIN" => "old.example.com"
      })
      |> read_prod_config()

    assert cfg[:public_url] == "https://new.example.com"
  end

  describe "RENDER_EXTERNAL_URL" do
    # Render injects it into every web service. It is in the fallback chain so
    # that render.yaml has something to boot on: PUBLIC_URL is required in
    # prod, and on Render the hostname does not exist until the first deploy
    # has already happened, so a blueprint that asked for it up front could
    # never complete its own first deploy.
    test "stands in for an unset PUBLIC_URL", %{base: base} do
      cfg =
        read_prod_config(
          Map.put(base, "RENDER_EXTERNAL_URL", "https://fountain-ab12.onrender.com")
        )

      assert cfg[:public_url] == "https://fountain-ab12.onrender.com"
      assert cfg[:phx_host] == "fountain-ab12.onrender.com"
    end

    test "loses to an operator's own PUBLIC_URL", %{base: base} do
      # What adding a custom domain looks like. The injected value does not go
      # away when the operator sets one, so the order is the whole feature.
      cfg =
        base
        |> Map.merge(%{
          "PUBLIC_URL" => "https://fountain.example.com",
          "RENDER_EXTERNAL_URL" => "https://fountain-ab12.onrender.com"
        })
        |> read_prod_config()

      assert cfg[:public_url] == "https://fountain.example.com"
    end

    test "a blank PUBLIC_URL falls through to it rather than winning", %{base: base} do
      # "" is truthy in Elixir, so the `||` chain this replaced would have
      # taken the empty string and raised. Every `${VAR:-}` and every
      # dashboard field left blank delivers exactly this shape.
      cfg =
        base
        |> Map.merge(%{
          "PUBLIC_URL" => "",
          "RENDER_EXTERNAL_URL" => "https://fountain-ab12.onrender.com"
        })
        |> read_prod_config()

      assert cfg[:public_url] == "https://fountain-ab12.onrender.com"
    end

    test "a blank one still raises rather than passing the check", %{base: base} do
      for k <-
            ~w(PUBLIC_URL PHX_HOST FOUNTAIN_DOMAIN RENDER_EXTERNAL_URL SMTP_HOST EMAIL_DELIVERY),
          do: System.delete_env(k)

      System.put_env(Map.put(base, "RENDER_EXTERNAL_URL", ""))

      assert_raise RuntimeError, ~r/PUBLIC_URL/, fn ->
        Config.Reader.read!(@runtime_exs, env: :prod)
      end
    end
  end

  test "endpoint scheme and port follow PUBLIC_URL for plain-HTTP self-hosts", %{base: base} do
    cfg = read_prod_config(Map.put(base, "PUBLIC_URL", "http://fountain.internal:4000"))

    url = cfg[FountainWeb.Endpoint][:url]
    assert url[:scheme] == "http"
    assert url[:port] == 4000
    assert url[:host] == "fountain.internal"
  end

  test "https keeps 443 so the hosted deployment is unchanged", %{base: base} do
    cfg = read_prod_config(Map.put(base, "PUBLIC_URL", "https://fountain.example.com"))

    url = cfg[FountainWeb.Endpoint][:url]
    assert url[:scheme] == "https"
    assert url[:port] == 443
  end

  test "check_origin lists the bare host", %{base: base} do
    cfg = read_prod_config(Map.put(base, "PUBLIC_URL", "https://fountain.example.com"))

    assert "//fountain.example.com" in cfg[FountainWeb.Endpoint][:check_origin]
  end

  describe "PUBLIC_URL is required in prod" do
    # The old fallback was http://localhost:4000 — and unlike a missing
    # secret, nothing crashed: the instance ran and silently put localhost
    # links in every verification email and every sprite's FOUNTAIN_BASE_URL.
    test "prod refuses to boot with neither PUBLIC_URL nor FOUNTAIN_DOMAIN", %{base: base} do
      for k <-
            ~w(PUBLIC_URL PHX_HOST FOUNTAIN_DOMAIN RENDER_EXTERNAL_URL SMTP_HOST EMAIL_DELIVERY),
          do: System.delete_env(k)

      System.put_env(base)

      error =
        assert_raise RuntimeError, fn ->
          Config.Reader.read!(@runtime_exs, env: :prod)
        end

      # Actionable: name the variable, the consequence, and the shape.
      assert error.message =~ "PUBLIC_URL"
      assert error.message =~ "localhost:4000"
      assert error.message =~ "https://fountain.example.com"
    end

    test "a blank PUBLIC_URL counts as unset", %{base: base} do
      # Compose-style `${VAR:-}` interpolation delivers "", not absence.
      for k <-
            ~w(PUBLIC_URL PHX_HOST FOUNTAIN_DOMAIN RENDER_EXTERNAL_URL SMTP_HOST EMAIL_DELIVERY),
          do: System.delete_env(k)

      System.put_env(Map.put(base, "PUBLIC_URL", ""))

      assert_raise RuntimeError, ~r/PUBLIC_URL/, fn ->
        Config.Reader.read!(@runtime_exs, env: :prod)
      end
    end

    test "dev keeps the localhost default", %{base: base} do
      for k <-
            ~w(PUBLIC_URL PHX_HOST FOUNTAIN_DOMAIN RENDER_EXTERNAL_URL SMTP_HOST EMAIL_DELIVERY),
          do: System.delete_env(k)

      System.put_env(base)
      cfg = Config.Reader.read!(@runtime_exs, env: :dev)[:fountain]

      assert cfg[:public_url] == "http://localhost:4000"
    end
  end
end
