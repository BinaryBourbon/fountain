defmodule Fountain.MailerConfigTest do
  @moduledoc """
  Mail delivery configuration.

  With nothing configured, prod used to fall back silently to
  `Swoosh.Adapters.Local` — an in-memory mailbox with no preview route outside
  dev. The verification email went nowhere, and since login is refused while
  `email_verified_at` is nil, the first signup on a fresh instance dead-ended
  with nothing pointing at the cause. The only escapes were GitHub OAuth, which
  auto-verifies, or editing the database by hand.

  SMTP is the other half: `SMTP_*` variables appear in the launch checklist, the
  engineering plan and the auth brief, and were never implemented — so an
  operator following the checklist set variables that did nothing.
  """

  # Mutates process env, so it must not run alongside anything else.
  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)

  @base %{
    "PHX_SERVER" => "true",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db"
  }

  @mail_vars ~w(RESEND_API_KEY SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_TLS EMAIL_DELIVERY)

  setup do
    previous = System.get_env()
    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    on_exit(fn ->
      System.put_env(previous)

      for k <- @mail_vars ++ ["MASTER_SECRETS_KEY"],
          not Map.has_key?(previous, k),
          do: System.delete_env(k)
    end)

    {:ok, base: Map.put(@base, "MASTER_SECRETS_KEY", key)}
  end

  defp read_prod(env) do
    for k <- @mail_vars, do: System.delete_env(k)
    System.put_env(env)
    Config.Reader.read!(@runtime_exs, env: :prod)[:fountain][Fountain.Mailer]
  end

  describe "with nothing configured" do
    test "prod refuses to boot rather than discarding mail silently", %{base: base} do
      for k <- @mail_vars, do: System.delete_env(k)
      System.put_env(base)

      error =
        assert_raise RuntimeError, fn ->
          Config.Reader.read!(@runtime_exs, env: :prod)
        end

      # The message has to be actionable — the old failure was silent, and a
      # cryptic one would not be much better.
      assert error.message =~ "No mail delivery is configured"
      assert error.message =~ "RESEND_API_KEY"
      assert error.message =~ "SMTP_HOST"
      assert error.message =~ "EMAIL_DELIVERY=none"
      assert error.message =~ "Fountain.Release.verify_email"
    end
  end

  describe "Resend" do
    test "is used when an API key is present", %{base: base} do
      config = read_prod(Map.put(base, "RESEND_API_KEY", "re_live_abc"))

      assert config[:adapter] == Swoosh.Adapters.Resend
      assert config[:api_key] == "re_live_abc"
    end
  end

  describe "SMTP" do
    test "is used when a host is present", %{base: base} do
      config =
        base
        |> Map.merge(%{
          "SMTP_HOST" => "smtp.example.com",
          "SMTP_USERNAME" => "postmaster",
          "SMTP_PASSWORD" => "hunter2hunter2"
        })
        |> read_prod()

      assert config[:adapter] == Swoosh.Adapters.SMTP
      assert config[:relay] == "smtp.example.com"
      assert config[:username] == "postmaster"
      assert config[:auth] == :always
    end

    test "defaults to port 587 with STARTTLS", %{base: base} do
      config = read_prod(Map.put(base, "SMTP_HOST", "smtp.example.com"))

      assert config[:port] == 587
      assert config[:tls] == :always
    end

    test "port and TLS mode are overridable", %{base: base} do
      config =
        base
        |> Map.merge(%{
          "SMTP_HOST" => "relay.internal",
          "SMTP_PORT" => "25",
          "SMTP_TLS" => "never"
        })
        |> read_prod()

      assert config[:port] == 25
      assert config[:tls] == :never
    end

    test "skips auth when no username is given", %{base: base} do
      # An unauthenticated relay on a trusted network is a legitimate setup and
      # must not be sent an empty username.
      config = read_prod(Map.put(base, "SMTP_HOST", "relay.internal"))

      assert config[:auth] == :never
    end

    test "Resend wins when both are set", %{base: base} do
      config =
        base
        |> Map.merge(%{"RESEND_API_KEY" => "re_x", "SMTP_HOST" => "smtp.example.com"})
        |> read_prod()

      assert config[:adapter] == Swoosh.Adapters.Resend
    end
  end

  describe "EMAIL_DELIVERY=none" do
    test "boots without configuring an adapter", %{base: base} do
      # Deliberate opt-out for an OAuth-only or evaluation instance. It must be
      # possible, just not the accidental default.
      config = read_prod(Map.put(base, "EMAIL_DELIVERY", "none"))

      # No prod override, so the base Local adapter from config.exs stands.
      assert config == nil or config[:adapter] == Swoosh.Adapters.Local
    end
  end
end
