defmodule FountainCli.SecretResolvers do
  @moduledoc """
  Registry of `FountainCli.SecretResolver` implementations.

  Order matters only if two resolvers have prefixes where one is a
  prefix of the other (none currently do). The first match wins.
  """

  @resolvers [
    FountainCli.OnePassword,
    FountainCli.Bitwarden,
    FountainCli.Infisical
  ]

  @doc "All registered resolvers in lookup order."
  @spec all() :: [module()]
  def all, do: @resolvers

  @doc """
  Find the resolver claiming this value, if any. Returns the module
  on a hit, `nil` if the value is a literal (no scheme matched).
  """
  @spec for_value(any()) :: module() | nil
  def for_value(value) when is_binary(value) do
    Enum.find(@resolvers, fn mod -> String.starts_with?(value, mod.prefix()) end)
  end

  def for_value(_), do: nil
end
