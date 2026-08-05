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
    "DATABASE_URL" => "postgres://u:p@localhost/db",
    "PUBLIC_URL" => "https://fountain.example.com",
    "EMAIL_FROM" => "noreply@fountain.example.com"
  }

  @mail_vars ~w(RESEND_API_KEY SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_TLS EMAIL_DELIVERY EMAIL_FROM)

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

  defp read_prod_full(env) do
    for k <- @mail_vars, do: System.delete_env(k)
    System.put_env(env)
    Config.Reader.read!(@runtime_exs, env: :prod)[:fountain]
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
      # Since ADR 0011 the opt-out self-verifies accounts; the message must
      # say so rather than send operators to a release task.
      assert error.message =~ "self-verify"
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

  describe "compose-style empty strings (#396)" do
    # docker-compose.yml passes optional vars as `${VAR:-}`, which interpolates
    # to an empty *string* — the variable is set, not absent — and "" is truthy
    # in Elixir. These tests therefore SET the variables to "" rather than
    # deleting them; deleting is the case every other test already covers and
    # is exactly how this bug survived.
    test "a blank RESEND_API_KEY does not select the Resend adapter", %{base: base} do
      # The stock compose file: EMAIL_DELIVERY=none plus every mail var blank.
      # The opt-out branch must be reachable, not shadowed by Resend.
      config =
        base
        |> Map.merge(%{
          "RESEND_API_KEY" => "",
          "SMTP_HOST" => "",
          "SMTP_USERNAME" => "",
          "SMTP_PASSWORD" => "",
          "EMAIL_DELIVERY" => "none"
        })
        |> read_prod()

      assert config == nil or config[:adapter] == Swoosh.Adapters.Local
    end

    test "a blank RESEND_API_KEY does not shadow a configured SMTP host", %{base: base} do
      config =
        base
        |> Map.merge(%{"RESEND_API_KEY" => "", "SMTP_HOST" => "smtp.example.com"})
        |> read_prod()

      assert config[:adapter] == Swoosh.Adapters.SMTP
      assert config[:relay] == "smtp.example.com"
    end

    test "a blank SMTP_USERNAME skips auth", %{base: base} do
      # `${SMTP_USERNAME:-}` against an unauthenticated relay must not force
      # auth: :always with an empty username.
      config =
        base
        |> Map.merge(%{"SMTP_HOST" => "relay.internal", "SMTP_USERNAME" => ""})
        |> read_prod()

      assert config[:auth] == :never
      assert config[:username] == nil
    end

    test "all-blank mail vars still refuse to boot", %{base: base} do
      # Blank must behave exactly like unset: with no EMAIL_DELIVERY opt-out,
      # the actionable raise fires rather than Resend being selected with "".
      for k <- @mail_vars, do: System.delete_env(k)

      base
      |> Map.merge(%{"RESEND_API_KEY" => "", "SMTP_HOST" => "", "SMTP_USERNAME" => ""})
      |> System.put_env()

      error =
        assert_raise RuntimeError, fn ->
          Config.Reader.read!(@runtime_exs, env: :prod)
        end

      assert error.message =~ "No mail delivery is configured"
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

  describe "EMAIL_FROM" do
    # The old default was the hosted instance's sending domain: a self-hoster
    # who configured a provider but not EMAIL_FROM sent mail as someone
    # else's domain — rejected by any provider checking SPF/DKIM, and wrong
    # even where it wasn't.
    test "prod refuses to boot with a provider configured and no EMAIL_FROM", %{base: base} do
      env = base |> Map.delete("EMAIL_FROM") |> Map.put("RESEND_API_KEY", "re_live_abc")

      for k <- @mail_vars, do: System.delete_env(k)
      System.put_env(env)

      error =
        assert_raise RuntimeError, fn ->
          Config.Reader.read!(@runtime_exs, env: :prod)
        end

      assert error.message =~ "EMAIL_FROM"
      assert error.message =~ "SPF/DKIM"
    end

    test "a blank EMAIL_FROM counts as unset with SMTP configured", %{base: base} do
      # `${EMAIL_FROM:-}` under compose delivers "", not absence.
      env =
        base
        |> Map.merge(%{"EMAIL_FROM" => "", "SMTP_HOST" => "smtp.example.com"})

      for k <- @mail_vars, do: System.delete_env(k)
      System.put_env(env)

      assert_raise RuntimeError, ~r/EMAIL_FROM/, fn ->
        Config.Reader.read!(@runtime_exs, env: :prod)
      end
    end

    test "is used verbatim when set", %{base: base} do
      config = read_prod_full(Map.put(base, "RESEND_API_KEY", "re_live_abc"))

      assert config[:email_from] == "noreply@fountain.example.com"
    end

    test "falls back to a neutral placeholder when mail is off", %{base: base} do
      # Nothing is ever sent in this mode; the placeholder must not be a real
      # domain someone owns.
      config =
        base
        |> Map.delete("EMAIL_FROM")
        |> Map.put("EMAIL_DELIVERY", "none")
        |> read_prod_full()

      assert config[:email_from] == "noreply@localhost"
    end
  end
end
