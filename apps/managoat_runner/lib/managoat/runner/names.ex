defmodule Managoat.Runner.Names do
  @moduledoc """
  Sandbox names on the runner provider carry the runner id, because
  `Managoat.Sandbox` hands an adapter nothing but the name: the shape is
  `runner-<32 hex>-<8 hex>`, the runner's UUID without dashes and a random
  suffix.

  Pure functions. Which runner a *new* sandbox should be minted on is the
  host's placement policy and is not here.
  """

  @doc "Mint a sandbox name on the runner: `runner-<32 hex>-<8 hex>`."
  @spec for_runner(binary()) :: String.t()
  def for_runner(runner_id) when is_binary(runner_id) do
    short = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "runner-#{String.replace(runner_id, "-", "")}-#{short}"
  end

  @doc "Recover the runner id (as a lowercase dashed UUID) from a sandbox name."
  @spec parse(String.t()) :: {:ok, binary()} | :error
  def parse("runner-" <> rest) do
    with <<hex::binary-size(32), "-", _short::binary>> <- rest,
         true <- hex?(hex) do
      {:ok, hex |> String.downcase() |> dashed()}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  defp hex?(bin), do: Regex.match?(~r/\A[0-9a-fA-F]{32}\z/, bin)

  defp dashed(
         <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
           e::binary-size(12)>>
       ),
       do: "#{a}-#{b}-#{c}-#{d}-#{e}"
end
