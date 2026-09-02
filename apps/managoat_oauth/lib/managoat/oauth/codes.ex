defmodule Managoat.OAuth.Codes do
  @moduledoc """
  The authorization-code half of the state machine: issue a code on
  consent, exchange it once for a token the host mints. Codes live five
  minutes, are stored hashed, and are bound to the subject, the client, the
  redirect URI and the PKCE challenge the exchange must answer.
  """

  import Ecto.Query, warn: false

  alias Managoat.OAuth.{AuthorizationCode, Clients, Config}

  @code_ttl_seconds 300
  @token_ttl_seconds 30 * 24 * 3600

  @doc false
  @spec token_ttl_seconds() :: pos_integer()
  def token_ttl_seconds, do: @token_ttl_seconds

  @doc false
  @spec authorize(Config.t(), binary(), map(), keyword()) ::
          {:ok, String.t()} | {:error, atom() | Ecto.Changeset.t()}
  def authorize(%Config{} = config, subject, params, opts) when is_binary(subject) do
    with {:ok, client} <- Clients.validate_request(config.clients, params) do
      raw = random_token()

      %AuthorizationCode{}
      |> AuthorizationCode.changeset(%{
        code_hash: hash(raw),
        subject_id: subject,
        client_id: client.id,
        redirect_uri: params["redirect_uri"],
        code_challenge: params["code_challenge"],
        expires_at: now_s() |> DateTime.add(@code_ttl_seconds, :second)
      })
      |> config.repo.insert(Config.repo_opts(config))
      |> case do
        {:ok, _code} ->
          _ =
            config.host.audit(
              :authorized,
              %{subject_id: subject, client_id: client.id, redirect_uri: params["redirect_uri"]},
              opts
            )

          {:ok, raw}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc false
  @spec exchange(Config.t(), map(), keyword()) ::
          {:ok, %{access_token: String.t(), expires_in: pos_integer(), api_key: term()}}
          | {:error, :invalid_grant | :server_error}
  def exchange(%Config{} = config, params, opts) when is_map(params) do
    now = now_s()
    repo_opts = Config.repo_opts(config)

    with code when is_binary(code) <- params["code"] || {:error, :invalid_grant},
         verifier when is_binary(verifier) <- params["code_verifier"] || {:error, :invalid_grant},
         %AuthorizationCode{} = row <-
           config.repo.get_by(AuthorizationCode, [code_hash: hash(code)], repo_opts) ||
             {:error, :invalid_grant},
         true <- row.client_id == params["client_id"] || {:error, :invalid_grant},
         true <- row.redirect_uri == params["redirect_uri"] || {:error, :invalid_grant},
         true <- DateTime.compare(row.expires_at, now) == :gt || {:error, :invalid_grant},
         true <- pkce_verify(verifier, row.code_challenge) || {:error, :invalid_grant},
         {1, _} <- mark_used(config, row.id, now) do
      # The code is consumed before the host mints, on purpose: a code is
      # proof of one consent, and a mint that fails answers :server_error
      # rather than leaving a live code behind. See the Managoat.OAuth
      # moduledoc; there is a test for it.
      expires_at = DateTime.add(now, @token_ttl_seconds, :second)

      grant = %{
        type: :authorization_code,
        id: row.id,
        client_id: row.client_id,
        expires_at: expires_at
      }

      case config.host.issue_token(row.subject_id, grant, opts) do
        {:ok, %{access_token: access_token, token: token}} ->
          {:ok, %{access_token: access_token, expires_in: @token_ttl_seconds, api_key: token}}

        {:error, _} ->
          {:error, :server_error}
      end
    else
      {0, _} -> {:error, :invalid_grant}
      {:error, _} = err -> err
      _ -> {:error, :invalid_grant}
    end
  end

  # Single use is the conditional update: two concurrent exchanges of one
  # code cannot both see {1, _}.
  defp mark_used(config, id, now) do
    from(c in AuthorizationCode, where: c.id == ^id and is_nil(c.used_at))
    |> config.repo.update_all([set: [used_at: now]], Config.repo_opts(config))
  end

  @doc false
  @spec pkce_verify(term(), term()) :: boolean()
  def pkce_verify(verifier, challenge) when is_binary(verifier) and is_binary(challenge) do
    computed = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    byte_size(computed) == byte_size(challenge) and :crypto.hash_equals(computed, challenge)
  end

  def pkce_verify(_, _), do: false

  @doc false
  @spec prune_expired(Config.t()) :: non_neg_integer()
  def prune_expired(%Config{} = config) do
    now = DateTime.utc_now()

    {count, _} =
      config.repo.delete_all(
        from(c in AuthorizationCode, where: c.expires_at < ^now),
        Config.repo_opts(config)
      )

    count
  end

  @doc false
  @spec random_token() :: String.t()
  def random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc false
  @spec hash(binary()) :: String.t()
  def hash(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)

  @doc false
  @spec now_s() :: DateTime.t()
  def now_s, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
