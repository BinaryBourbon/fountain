defmodule Fountain.Team.Comms.Phone do
  @moduledoc """
  Phone numbers as E.164 (`+15551234567`), the one shape AgentPhone speaks
  and the one `team_contacts` stores. `normalize/1` is forgiving about what
  people type — spaces, dashes, parentheses, a leading `1` or none on a US
  number — and strict about what comes out.
  """

  @e164 ~r/^\+[1-9]\d{6,14}$/

  @doc """
  `{:ok, "+1555..."}` or `:error`. A bare 10-digit number is taken as US/CA;
  an 11-digit number starting with 1 likewise; anything else must carry its
  own `+` country code.
  """
  @spec normalize(term) :: {:ok, String.t()} | :error
  def normalize(value) when is_binary(value) do
    digits = String.replace(value, ~r/[\s().-]/, "")

    candidate =
      cond do
        String.starts_with?(digits, "+") -> digits
        String.starts_with?(digits, "00") -> "+" <> String.slice(digits, 2..-1//1)
        Regex.match?(~r/^\d{10}$/, digits) -> "+1" <> digits
        Regex.match?(~r/^1\d{10}$/, digits) -> "+" <> digits
        true -> digits
      end

    if Regex.match?(@e164, candidate), do: {:ok, candidate}, else: :error
  end

  def normalize(_), do: :error

  @doc "Whether two numbers are the same once normalized."
  def same?(a, b) do
    case {normalize(a), normalize(b)} do
      {{:ok, x}, {:ok, y}} -> x == y
      _ -> false
    end
  end
end
