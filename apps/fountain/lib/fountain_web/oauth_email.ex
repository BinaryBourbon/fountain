defmodule FountainWeb.OauthEmail do
  @moduledoc """
  Extracts a provider-verified email address from an Ueberauth result.

  `Accounts.upsert_oauth_user/3` links a new OAuth identity to any existing
  account with a matching email. That is the convenient behaviour and it is only
  safe if the provider actually asserts the address belongs to the person
  signing in.

  It did not. `ueberauth_github`'s `maybe_get_primary_email/1` picks the address
  flagged `primary` out of `/user/emails` and never looks at the `verified`
  field beside it, so a GitHub account whose primary address is added but not
  yet confirmed still produced an `auth.info.email`. The controller checked only
  that the string was non-empty. Set an unconfirmed primary address to a
  victim's, sign in with GitHub, and the identity attaches to their existing
  password account.

  So the verified flag is read here from the raw provider payload rather than
  trusting `auth.info.email`, and an address the provider will not vouch for is
  refused outright.
  """

  @doc """
  Returns `{:ok, email}` when the provider asserts the address is verified.

  `{:error, :no_email}` when there is no address at all, and
  `{:error, :unverified}` when there is one the provider has not confirmed.
  """
  @spec verified_email(map()) :: {:ok, String.t()} | {:error, :no_email | :unverified}
  def verified_email(auth) do
    case email_from(auth) do
      nil -> {:error, :no_email}
      "" -> {:error, :no_email}
      email -> if verified?(auth, email), do: {:ok, email}, else: {:error, :unverified}
    end
  end

  defp email_from(auth), do: get_in(auth, [Access.key(:info), Access.key(:email)])

  # GitHub's /user/emails entries carry both `primary` and `verified`. Match on
  # the address we were handed rather than on `primary`, since they can differ.
  defp verified?(auth, email) do
    auth
    |> raw_emails()
    |> Enum.any?(fn entry ->
      String.downcase(to_string(entry["email"] || "")) == String.downcase(email) and
        entry["verified"] == true
    end)
  end

  defp raw_emails(auth) do
    case get_in(auth, [Access.key(:extra), Access.key(:raw_info)]) do
      %{user: %{"emails" => emails}} when is_list(emails) -> emails
      %{"user" => %{"emails" => emails}} when is_list(emails) -> emails
      _ -> []
    end
  end

  @doc """
  Message shown to someone we refused, phrased so they can fix it themselves.
  """
  @spec explain(:no_email | :unverified) :: String.t()
  def explain(:no_email) do
    "GitHub did not return an email address. Grant the `user:email` scope, or " <>
      "add a public email to your GitHub account, and try again."
  end

  def explain(:unverified) do
    "GitHub has not verified that email address. Confirm it in your GitHub " <>
      "email settings and try signing in again."
  end
end
