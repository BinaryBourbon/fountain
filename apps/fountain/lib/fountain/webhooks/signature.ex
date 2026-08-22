defmodule Fountain.Webhooks.Signature do
  @moduledoc """
  The `Fountain-Signature` header: Stripe-shaped, because every integrator has
  already written this verifier once.

      Fountain-Signature: t=1755203400,v1=<hex hmac_sha256(secret, "1755203400.<raw body>")>

  The timestamp is **inside** the signed string, so a receiver can enforce a
  replay window and an attacker cannot move a captured body forward in time.
  `v1` is the scheme version; a receiver should look up the pair by name
  rather than by position, so a `v2` can be added alongside it.

  `verify/4` is here for two reasons: the test suite checks our own header
  against an independent implementation of the rule, and the docs page points
  at this module as the reference. Fountain never receives its own webhooks.
  """

  @default_tolerance 300

  @doc "The header value for `body`, signed with `secret` at `timestamp` (unix seconds)."
  @spec header(String.t(), String.t(), integer()) :: String.t()
  def header(secret, body, timestamp)
      when is_binary(secret) and is_binary(body) and is_integer(timestamp) do
    "t=#{timestamp},v1=#{hex_mac(secret, body, timestamp)}"
  end

  @doc "The hex-encoded v1 MAC on its own."
  @spec hex_mac(String.t(), String.t(), integer()) :: String.t()
  def hex_mac(secret, body, timestamp) do
    :hmac
    |> :crypto.mac(:sha256, secret, "#{timestamp}.#{body}")
    |> Base.encode16(case: :lower)
  end

  @doc """
  Check a header against a body and secret.

  `:ok`, or `{:error, :malformed | :no_v1 | :stale | :mismatch}`. The MAC
  comparison is constant-time; the staleness check runs first so a receiver
  outside the window never gets as far as comparing.
  """
  @spec verify(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, :malformed | :no_v1 | :stale | :mismatch}
  def verify(header, body, secret, opts \\ []) when is_binary(header) do
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, parts} <- parse(header),
         {:ok, timestamp} <- fetch_timestamp(parts),
         :ok <- check_age(timestamp, now, tolerance),
         {:ok, given} <- fetch_v1(parts) do
      if Plug.Crypto.secure_compare(given, hex_mac(secret, body, timestamp)),
        do: :ok,
        else: {:error, :mismatch}
    end
  end

  defp parse(header) do
    parts =
      header
      |> String.split(",")
      |> Enum.flat_map(fn part ->
        case String.split(String.trim(part), "=", parts: 2) do
          [k, v] -> [{k, v}]
          _ -> []
        end
      end)

    if parts == [], do: {:error, :malformed}, else: {:ok, parts}
  end

  defp fetch_timestamp(parts) do
    with {_, raw} <- List.keyfind(parts, "t", 0, :missing),
         {ts, ""} <- Integer.parse(raw) do
      {:ok, ts}
    else
      _ -> {:error, :malformed}
    end
  end

  defp fetch_v1(parts) do
    case List.keyfind(parts, "v1", 0) do
      {_, mac} -> {:ok, mac}
      nil -> {:error, :no_v1}
    end
  end

  defp check_age(timestamp, now, tolerance) do
    if abs(now - timestamp) <= tolerance, do: :ok, else: {:error, :stale}
  end
end
