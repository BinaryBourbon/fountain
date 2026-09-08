defmodule Fountain.PlatformChatGPT do
  @moduledoc """
  The deployment's ChatGPT grant for the codex runtime (ADR 0047), beside
  its platform API keys (`Fountain.PlatformInference`).

  An admin signs the Fountain **server** in to ChatGPT once, by pasting the
  `auth.json` a laptop's `codex login` wrote or by the device-code flow
  (`Fountain.PlatformChatGPT.Device`). From then on Fountain owns the
  refresh token and is the only thing that ever uses it: the token rotates
  and is single-use, so a second holder would kill the grant for both. A
  sandbox never sees it. What a sandbox gets is `auth.json` in
  `chatgptAuthTokens` mode with a placeholder where the bearer goes
  (`Fountain.Conversations.CodexChatGPT`), and the broker substitutes the
  current access token on `chatgpt.com` (`Fountain.Broker`).

  ## What is here

    * `access_token/0` — the current access token, refreshed when it is
      within `PLATFORM_CHATGPT_REFRESH_MARGIN_SECONDS` of its expiry, under
      an advisory lock so two conversations cannot both spend the one
      refresh token. The rotated refresh token is persisted *before* the new
      access token is handed out. A terminal refusal marks the row `revoked`
      with the server's reason code; a workspace token past its expiry
      marks it `expired`.
    * `credential/0` — `{:ok, token}` or `:none`, for
      `Fountain.InferenceCredentials.select/3`, which takes the grant for a
      codex agent whose tenant has no OpenAI key of their own.
    * `sandbox_auth/0` — the account id and the synthesised `id_token` the
      sandbox file carries; never the real one.
    * `connect_from_auth_json/2`, `connect_from_tokens/3`,
      `connect_workspace_token/3`, `disconnect/1` — the admin mutations,
      each leaving an `admin.platform_chatgpt.*` row on the privilege trail.
      Never a token, never a claim that is a secret.
    * `keepalive/0` — refresh a grant nobody has used for
      `PLATFORM_CHATGPT_KEEPALIVE_DAYS`, so it never idles past the auth
      server's window (`Fountain.Workers.PlatformChatGPTKeepalive`).
    * `status/0` — what the admin page shows.

  The refresh margin must exceed the longest turn the deployment expects:
  a turn that outlives its access token fails at the proxy, because codex
  cannot refresh in this mode. The default is fifteen minutes.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.Audit
  alias Fountain.Crypto
  alias Fountain.PlatformChatGPT.{Account, OAuth, Tokens}
  alias Fountain.Repo

  # Its own namespace beside Connections' 4331; there is one platform row,
  # so the key is constant.
  @refresh_lock_namespace 4332
  @refresh_lock_key 1

  @system_actor "system:platform_chatgpt"

  # ── reads ────────────────────────────────────────────────────────────────

  @doc "Whether the deployment holds a usable grant right now (no refresh is attempted)."
  @spec active?() :: boolean()
  def active?, do: match?(%Account{status: "active"}, platform_row())

  @doc """
  The grant as `Fountain.InferenceCredentials.select/3` wants it:
  `{:ok, access_token}` when it is active and refreshable, else `:none`.
  """
  @spec credential() :: {:ok, String.t()} | :none
  def credential do
    case access_token() do
      {:ok, token} -> {:ok, token}
      _ -> :none
    end
  end

  @doc """
  A valid access token, refreshing when within the margin of expiry.
  `{:error, :not_connected}`, `{:error, :revoked}` or `{:error, :expired}`
  when there is nothing to hand out; a transient refresh failure comes
  back as its reason and the caller keeps what it has.
  """
  @spec access_token() :: {:ok, String.t()} | {:error, term()}
  def access_token do
    case platform_row() do
      nil -> {:error, :not_connected}
      %Account{status: "revoked"} -> {:error, :revoked}
      %Account{status: "expired"} -> {:error, :expired}
      %Account{} = row -> serve(row)
    end
  end

  defp serve(row) do
    cond do
      fresh?(row) -> decrypt(row.access_token_ciphertext)
      is_nil(row.refresh_token_ciphertext) -> expire_or_serve(row)
      true -> refresh_locked(row, :if_stale)
    end
  end

  # A workspace token has no refresh token: it is served until it has
  # really lapsed (the margin is for refreshing, not for cutting off), then
  # the row goes `expired`.
  defp expire_or_serve(row) do
    if lapsed?(row) do
      _ = mark_expired(row)
      {:error, :expired}
    else
      decrypt(row.access_token_ciphertext)
    end
  end

  @doc """
  What the sandbox's `auth.json` carries beside the placeholder: the real
  account id (not a secret; it goes in a header codex sends in the clear)
  and an unsigned `id_token` built from the stored claims.
  """
  @spec sandbox_auth() :: {:ok, %{account_id: String.t(), id_token: String.t()}} | :none
  def sandbox_auth do
    case platform_row() do
      %Account{status: "active", account_id: account_id, id_claims: claims}
      when is_binary(account_id) ->
        {:ok, %{account_id: account_id, id_token: Tokens.synthesize_id_token(claims)}}

      _ ->
        :none
    end
  end

  @doc """
  The row for `/admin/inference`: `:not_connected`, or a map with `:status`
  (`"active"` | `"revoked"` | `"expired"`), `:kind`, `:account_email`,
  `:plan_type`, `:account_id`, `:access_expires_at`, `:last_refreshed_at`,
  `:revoked_reason`, `:updated_at` and `:updated_by`.
  """
  @spec status() :: :not_connected | map()
  def status do
    case platform_row([:updated_by]) do
      nil ->
        :not_connected

      row ->
        %{
          status: row.status,
          kind: row.kind,
          account_email: row.account_email,
          plan_type: row.plan_type,
          account_id: row.account_id,
          access_expires_at: row.access_expires_at,
          last_refreshed_at: row.last_refreshed_at,
          revoked_reason: row.revoked_reason,
          updated_at: row.updated_at,
          updated_by: row.updated_by && row.updated_by.email
        }
    end
  end

  # ── connect / disconnect ─────────────────────────────────────────────────

  @doc """
  Connect from the `auth.json` a laptop's `codex login` wrote (OpenAI's own
  CI recipe). Refused unless it is a ChatGPT login with a refresh token.
  From here on that file is Fountain's: using it anywhere else breaks both.
  """
  @spec connect_from_auth_json(String.t(), keyword()) ::
          {:ok, Account.t()} | {:error, term()}
  def connect_from_auth_json(json, opts \\ []) do
    with {:ok, tokens} <- Tokens.parse_auth_json(json) do
      connect_from_tokens(tokens, "paste", opts)
    end
  end

  @doc """
  Store a token set from a paste or the device flow. `method` is recorded
  on the `admin.platform_chatgpt.connected` event. The `id_token` must
  carry an account id: without it codex has nothing to send in
  `chatgpt-account-id`, and the backend refuses the request.
  """
  @spec connect_from_tokens(OAuth.tokens(), String.t(), keyword()) ::
          {:ok, Account.t()} | {:error, term()}
  def connect_from_tokens(%{access_token: access} = tokens, method, opts \\ [])
      when is_binary(access) and is_binary(method) do
    with refresh when is_binary(refresh) and refresh != "" <-
           Map.get(tokens, :refresh_token) || {:error, :no_refresh_token},
         {:ok, claims} <- Tokens.claims(Map.get(tokens, :id_token) || "") do
      actor_user_id = Keyword.get(opts, :actor_user_id)

      attrs = %{
        kind: "chatgpt",
        refresh_token_ciphertext: Crypto.encrypt_platform(refresh),
        access_token_ciphertext: Crypto.encrypt_platform(access),
        id_claims: Map.drop(claims, ["email"]),
        account_id: claims["account_id"],
        account_email: claims["email"],
        plan_type: claims["plan_type"],
        access_expires_at: Tokens.expires_at(access),
        last_refreshed_at: now(),
        updated_by_user_id: actor_user_id
      }

      store(attrs, method, actor_user_id)
    else
      {:error, _} = error -> error
      _ -> {:error, :no_refresh_token}
    end
  end

  @doc """
  Connect with a ChatGPT Business or Enterprise workspace access token
  (`CODEX_ACCESS_TOKEN`): static, non-refreshing, and OpenAI's sanctioned
  non-interactive credential, so where it exists it is the one to use.
  `expires_on` is the expiry the admin console shows, or nil for none;
  the row goes `expired` when it passes. The account id is taken from the
  token when it is a JWT, else from `:account_id` in `opts`.
  """
  @spec connect_workspace_token(String.t(), Date.t() | nil, keyword()) ::
          {:ok, Account.t()} | {:error, term()}
  def connect_workspace_token(token, expires_on, opts \\ []) when is_binary(token) do
    token = String.trim(token)
    actor_user_id = Keyword.get(opts, :actor_user_id)

    with :ok <- validate_token(token),
         {:ok, account_id, claims} <- workspace_claims(token, Keyword.get(opts, :account_id)) do
      attrs = %{
        kind: "workspace_token",
        refresh_token_ciphertext: nil,
        access_token_ciphertext: Crypto.encrypt_platform(token),
        id_claims: claims,
        account_id: account_id,
        account_email: nil,
        plan_type: claims["plan_type"] || "workspace",
        access_expires_at: workspace_expiry(token, expires_on),
        last_refreshed_at: now(),
        updated_by_user_id: actor_user_id
      }

      store(attrs, "workspace_token", actor_user_id)
    end
  end

  @doc """
  Forget the grant. Running conversations keep the session they hold until
  their next turn's re-read; new codex conversations fall through to the
  platform `OPENAI_API_KEY`, or to no credential. `:ok` either way; the
  event is recorded only when a row was there.
  """
  @spec disconnect(keyword()) :: :ok
  def disconnect(opts \\ []) do
    case platform_row() do
      nil ->
        :ok

      %Account{} = row ->
        Repo.delete!(row)

        Audit.record_admin(%{
          actor_user_id: Keyword.get(opts, :actor_user_id),
          event_type: "admin.platform_chatgpt.disconnected",
          metadata: %{"account_id" => row.account_id, "kind" => row.kind}
        })

        :ok
    end
  end

  defp store(attrs, method, actor_user_id) do
    result =
      (platform_row() || %Account{})
      |> Account.connect_changeset(attrs)
      |> Repo.insert_or_update()

    case result do
      {:ok, account} ->
        Audit.record_admin(%{
          actor_user_id: actor_user_id,
          event_type: "admin.platform_chatgpt.connected",
          metadata: %{
            "method" => method,
            "kind" => account.kind,
            "account_id" => account.account_id,
            "email" => account.account_email,
            "plan" => account.plan_type
          }
        })

        {:ok, account}

      {:error, _changeset} ->
        {:error, :invalid_grant}
    end
  end

  # ── refresh ──────────────────────────────────────────────────────────────

  @doc """
  Refresh the grant now if nobody has for `PLATFORM_CHATGPT_KEEPALIVE_DAYS`,
  whatever the access token's expiry says. `{:ok, :refreshed}`,
  `{:ok, :skipped}` (nothing to do: not connected, not a refreshable grant,
  or renewed recently), or the refresh's error.
  """
  @spec keepalive() :: {:ok, :refreshed | :skipped} | {:error, term()}
  def keepalive do
    case platform_row() do
      %Account{status: "active", refresh_token_ciphertext: cipher} = row
      when is_binary(cipher) ->
        if stale_for_keepalive?(row) do
          case refresh_locked(row, :force) do
            {:ok, _token} -> {:ok, :refreshed}
            {:error, _} = error -> error
          end
        else
          {:ok, :skipped}
        end

      _ ->
        {:ok, :skipped}
    end
  end

  # Serialized under an advisory lock, with the row re-read under it. Two
  # conversations refreshing the same stale grant would otherwise race: the
  # first rotates the refresh token, the second replays the stale one, and
  # the server answers `refresh_token_reused` — which would revoke a grant
  # that had just been renewed. The lock spans the round-trip.
  defp refresh_locked(_row, mode) do
    outcome =
      Repo.transaction(
        fn ->
          Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
            @refresh_lock_namespace,
            @refresh_lock_key
          ])

          case platform_row() do
            nil -> {:error, :not_connected}
            current -> locked_refresh(current, mode)
          end
        end,
        timeout: Application.get_env(:fountain, :connections_timeout_ms, 15_000) * 2 + 5_000
      )

    # The status write that follows a refusal audits, and an audit must not
    # run inside a transaction (ADR 0013), so it happens out here.
    case outcome do
      {:ok, {:refused, current, code}} ->
        _ = mark_revoked(current, code)
        {:error, :revoked}

      {:ok, result} ->
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A concurrent refresh may have finished while we waited on the lock: the
  # re-read row can already be fresh (serve it, unless forced), revoked or
  # expired (say so). Only a row still stale under the lock goes to the
  # server — with the refresh token the row holds *now*.
  defp locked_refresh(current, mode) do
    cond do
      current.status == "revoked" -> {:error, :revoked}
      current.status == "expired" -> {:error, :expired}
      is_nil(current.refresh_token_ciphertext) -> decrypt(current.access_token_ciphertext)
      mode == :if_stale and fresh?(current) -> decrypt(current.access_token_ciphertext)
      true -> do_refresh(current)
    end
  end

  defp do_refresh(current) do
    with {:ok, refresh} <- decrypt(current.refresh_token_ciphertext) do
      case OAuth.refresh(refresh) do
        {:ok, %{access_token: access} = fresh} ->
          # The rotated refresh token lands before the access token is
          # handed out: a crash between the two would otherwise leave the
          # row holding a refresh token the server has already retired.
          case current |> Account.refresh_changeset(refresh_attrs(fresh)) |> Repo.update() do
            {:ok, _} -> {:ok, access}
            {:error, changeset} -> {:error, changeset}
          end

        {:error, {:terminal, code}} ->
          {:refused, current, code}

        {:error, reason} ->
          Logger.warning(
            "platform chatgpt: refresh failed, keeping the current token: " <>
              inspect(reason)
          )

          {:error, reason}
      end
    end
  end

  defp refresh_attrs(%{access_token: access} = fresh) do
    base = %{
      access_token_ciphertext: Crypto.encrypt_platform(access),
      access_expires_at: Tokens.expires_at(access),
      last_refreshed_at: now()
    }

    base =
      case fresh[:refresh_token] do
        rotated when is_binary(rotated) and rotated != "" ->
          Map.put(base, :refresh_token_ciphertext, Crypto.encrypt_platform(rotated))

        _ ->
          base
      end

    case fresh[:id_token] && Tokens.claims(fresh[:id_token]) do
      {:ok, claims} ->
        Map.merge(base, %{
          id_claims: Map.drop(claims, ["email"]),
          account_id: claims["account_id"],
          account_email: claims["email"],
          plan_type: claims["plan_type"]
        })

      _ ->
        base
    end
  end

  defp mark_revoked(row, code) do
    result = row |> Account.revoke_changeset(code) |> Repo.update()

    Audit.record_admin(%{
      actor_user_id: nil,
      event_type: "admin.platform_chatgpt.revoked",
      metadata: %{"actor" => @system_actor, "reason" => code, "account_id" => row.account_id}
    })

    Logger.warning(
      "platform chatgpt: the auth server refused the refresh token (#{code}); " <>
        "codex conversations fall back to PLATFORM_OPENAI_API_KEY. Reconnect at /admin/inference."
    )

    result
  end

  defp mark_expired(row) do
    result = row |> Account.expire_changeset() |> Repo.update()

    Audit.record_admin(%{
      actor_user_id: nil,
      event_type: "admin.platform_chatgpt.expired",
      metadata: %{"actor" => @system_actor, "kind" => row.kind, "account_id" => row.account_id}
    })

    result
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp platform_row(preload \\ []) do
    from(a in Account, where: is_nil(a.user_id))
    |> Repo.one()
    |> case do
      nil -> nil
      row -> Repo.preload(row, preload)
    end
  end

  # No expiry known: the token stands until the server refuses it.
  defp fresh?(%Account{access_expires_at: nil}), do: true

  defp fresh?(%Account{access_expires_at: at}) do
    DateTime.diff(at, DateTime.utc_now(), :second) > refresh_margin_seconds()
  end

  defp lapsed?(%Account{access_expires_at: %DateTime{} = at}),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp lapsed?(_row), do: false

  defp stale_for_keepalive?(%Account{last_refreshed_at: nil}), do: true

  defp stale_for_keepalive?(%Account{last_refreshed_at: at}) do
    DateTime.diff(DateTime.utc_now(), at, :day) >= keepalive_days()
  end

  @doc "How far ahead of the access token's expiry a refresh happens (`PLATFORM_CHATGPT_REFRESH_MARGIN_SECONDS`, default 900)."
  @spec refresh_margin_seconds() :: non_neg_integer()
  def refresh_margin_seconds do
    case Application.get_env(:fountain, :platform_chatgpt_refresh_margin_seconds) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 900
    end
  end

  @doc "How long a grant may go unrefreshed before the keepalive renews it (`PLATFORM_CHATGPT_KEEPALIVE_DAYS`, default 6)."
  @spec keepalive_days() :: non_neg_integer()
  def keepalive_days do
    case Application.get_env(:fountain, :platform_chatgpt_keepalive_days) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 6
    end
  end

  defp decrypt(nil), do: {:error, :no_token}

  defp decrypt(blob) do
    case Crypto.decrypt_platform(blob) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Logger.warning(
          "platform chatgpt: the stored token does not decrypt under MASTER_SECRETS_KEY; " <>
            "reconnect at /admin/inference"
        )

        {:error, :undecryptable}
    end
  end

  # A workspace token is opaque or a JWT; either way the account id comes
  # from the token's claims when it has them, else from the admin.
  defp workspace_claims(token, given_account_id) do
    case Tokens.claims(token) do
      {:ok, claims} ->
        {:ok, claims["account_id"], Map.drop(claims, ["email"])}

      {:error, _} ->
        case given_account_id do
          id when is_binary(id) and id != "" -> {:ok, id, %{"account_id" => id}}
          _ -> {:ok, nil, %{}}
        end
    end
  end

  defp workspace_expiry(token, expires_on) do
    case {Tokens.expires_at(token), expires_on} do
      {%DateTime{} = at, _} -> at
      {nil, %Date{} = on} -> DateTime.new!(on, ~T[23:59:59], "Etc/UTC")
      {nil, _} -> nil
    end
  end

  # Long enough for any token seen so far, short enough that a pasted file
  # is refused rather than stored as a token.
  @max_token_bytes 8_192

  defp validate_token(""), do: {:error, :invalid_token}
  defp validate_token(t) when byte_size(t) > @max_token_bytes, do: {:error, :invalid_token}

  defp validate_token(t) do
    if Regex.match?(~r/[[:space:][:cntrl:]]/u, t), do: {:error, :invalid_token}, else: :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
