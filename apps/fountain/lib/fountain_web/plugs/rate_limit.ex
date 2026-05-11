defmodule FountainWeb.Plugs.RateLimit do
  @moduledoc """
  Lightweight ETS-based fixed-window rate limiter. Single-tenant, so the
  intent isn't anti-abuse multitenancy — it's anti-runaway: stop a buggy
  client from spamming sprite spawns or saturating the BEAM.

  Buckets are per-IP. The ETS table is created in `Fountain.Application`
  startup. Returns 429 + `Retry-After` (seconds) when the bucket is full.

  ## Options

    * `:bucket` — string label so multiple plug invocations don't share a
      counter (e.g. an "api" bucket and a "conversations" bucket).
    * `:max` — maximum requests per window.
    * `:window_ms` — window length in ms (default 60_000).

  ## Example

      pipeline :authed_api do
        plug FountainWeb.Plugs.RateLimit, bucket: "api", max: 120
      end

      scope "/api", FountainWeb do
        post "/conversations", ConversationController, :create
        plug FountainWeb.Plugs.RateLimit, bucket: "conv-create", max: 10
      end
  """

  import Plug.Conn

  @table :aod_rate_limit

  def table, do: @table

  @doc "Create the ETS table. Idempotent — safe to call from app startup."
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ref ->
        :ok
    end
  end

  def init(opts) do
    %{
      bucket: Keyword.fetch!(opts, :bucket),
      max: Keyword.fetch!(opts, :max),
      window_ms: Keyword.get(opts, :window_ms, 60_000)
    }
  end

  def call(conn, opts) do
    if Application.get_env(:fountain, :rate_limit_enabled, true) do
      ensure_table()
      key = key_for(conn, opts.bucket)

      case bump(key, opts) do
        :ok ->
          conn

        {:limited, retry_after_secs} ->
          conn
          |> put_resp_header("retry-after", to_string(retry_after_secs))
          |> put_resp_content_type("application/json")
          |> send_resp(
            429,
            Jason.encode!(%{error: "rate_limited", retry_after_seconds: retry_after_secs})
          )
          |> halt()
      end
    else
      conn
    end
  end

  # Exposed for tests.
  @doc false
  def bump(key, opts) do
    now = System.system_time(:millisecond)
    cutoff = now - opts.window_ms

    case :ets.lookup(@table, key) do
      [] ->
        :ets.insert(@table, {key, now, 1})
        :ok

      [{^key, started_at, _count}] when started_at < cutoff ->
        :ets.insert(@table, {key, now, 1})
        :ok

      [{^key, _started_at, count}] when count < opts.max ->
        :ets.update_counter(@table, key, {3, 1})
        :ok

      [{^key, started_at, _count}] ->
        retry_ms = opts.window_ms - (now - started_at)
        {:limited, max(div(retry_ms, 1000), 1)}
    end
  end

  defp key_for(conn, bucket) do
    {bucket, format_ip(conn.remote_ip)}
  end

  defp format_ip(nil), do: "unknown"
  defp format_ip(tuple) when is_tuple(tuple), do: tuple |> :inet.ntoa() |> to_string()
  defp format_ip(other), do: to_string(other)
end
