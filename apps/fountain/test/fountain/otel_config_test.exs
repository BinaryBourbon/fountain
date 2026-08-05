defmodule Fountain.OtelConfigTest do
  @moduledoc """
  Evaluates `config/runtime.exs` the way the release config provider does,
  pinning #317: trace export must be OFF unless an export target is
  explicitly configured. The old default was :otlp aimed at
  api.honeycomb.io, which made a stock self-host install attempt outbound
  telemetry to a third-party vendor.
  """

  # Mutates process env, so it must not run alongside anything else.
  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)

  @otel_vars ~w(OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS HONEYCOMB_ENDPOINT HONEYCOMB_API_KEY)

  @required %{
    "PHX_SERVER" => "true",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db",
    "RESEND_API_KEY" => "re_test_key",
    "EMAIL_FROM" => "noreply@fountain.example.com",
    "PUBLIC_URL" => "https://fountain.example.com"
  }

  setup do
    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    previous = System.get_env()

    on_exit(fn ->
      System.put_env(previous)

      for k <- @otel_vars ++ ~w(PUBLIC_URL PHX_HOST FOUNTAIN_DOMAIN RESEND_API_KEY EMAIL_DELIVERY),
          not Map.has_key?(previous, k),
          do: System.delete_env(k)
    end)

    {:ok, base: Map.put(@required, "MASTER_SECRETS_KEY", key)}
  end

  defp read_prod_config(env) do
    for k <- @otel_vars, do: System.delete_env(k)
    System.put_env(env)
    Config.Reader.read!(@runtime_exs, env: :prod)
  end

  test "with no export target configured, the traces exporter is off", %{base: base} do
    cfg = read_prod_config(base)

    assert cfg[:opentelemetry][:traces_exporter] == :none
  end

  test "an explicit OTLP endpoint turns the exporter on", %{base: base} do
    cfg = read_prod_config(Map.put(base, "OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318"))

    assert cfg[:opentelemetry][:traces_exporter] == :otlp
    assert cfg[:opentelemetry_exporter][:otlp_endpoint] == "http://collector:4318"
  end

  test "HONEYCOMB_API_KEY alone turns the exporter on with the auth header", %{base: base} do
    cfg = read_prod_config(Map.put(base, "HONEYCOMB_API_KEY", "hc-key"))

    assert cfg[:opentelemetry][:traces_exporter] == :otlp
    assert cfg[:opentelemetry_exporter][:otlp_endpoint] == "https://api.honeycomb.io"
    assert {"x-honeycomb-team", "hc-key"} in cfg[:opentelemetry_exporter][:otlp_headers]
  end

  test "HONEYCOMB_ENDPOINT alone turns the exporter on", %{base: base} do
    cfg = read_prod_config(Map.put(base, "HONEYCOMB_ENDPOINT", "https://api.eu1.honeycomb.io"))

    assert cfg[:opentelemetry][:traces_exporter] == :otlp
    assert cfg[:opentelemetry_exporter][:otlp_endpoint] == "https://api.eu1.honeycomb.io"
  end
end
