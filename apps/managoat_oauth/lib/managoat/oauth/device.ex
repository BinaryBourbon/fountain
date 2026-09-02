defmodule Managoat.OAuth.Device do
  @moduledoc """
  The device-authorization half of the state machine (RFC 8628 shape). A
  poller that cannot hold a password starts a grant, shows a human a short
  code and the host's approval page, and polls with its own high-entropy
  device code until a signed-in subject approves. Fifteen minutes to live,
  single use, one poll per interval.
  """

  import Ecto.Query, warn: false

  alias Managoat.OAuth.{Codes, Config, DeviceGrant}

  @device_ttl_seconds 900
  @device_interval_seconds 5
  # RFC 8628's suggested consonant alphabet: no vowels (no words, no
  # accidental profanity), no ambiguous glyphs. 20^8 codes for a
  # fifteen-minute, rate-limited window.
  @user_code_alphabet ~c"BCDFGHJKLMNPQRSTVWXZ"
  @user_code_length 8

  @doc false
  @spec interval_seconds() :: pos_integer()
  def interval_seconds, do: @device_interval_seconds

  @doc false
  @spec start(Config.t()) ::
          {:ok,
           %{
             device_code: String.t(),
             user_code: String.t(),
             expires_in: pos_integer(),
             interval: pos_integer()
           }}
          | {:error, :server_error}
  def start(%Config{} = config) do
    insert_grant(config, Codes.random_token(), _attempts_left = 3)
  end

  defp insert_grant(_config, _raw, 0), do: {:error, :server_error}

  defp insert_grant(config, raw, attempts_left) do
    user_code = generate_user_code()

    %DeviceGrant{}
    |> DeviceGrant.changeset(%{
      device_code_hash: Codes.hash(raw),
      user_code: user_code,
      expires_at: Codes.now_s() |> DateTime.add(@device_ttl_seconds, :second)
    })
    |> config.repo.insert(Config.repo_opts(config))
    |> case do
      {:ok, _grant} ->
        {:ok,
         %{
           device_code: raw,
           user_code: format_user_code(user_code),
           expires_in: @device_ttl_seconds,
           interval: @device_interval_seconds
         }}

      # A user_code collision (20^8 space, so effectively never) — roll again.
      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :user_code),
          do: insert_grant(config, raw, attempts_left - 1),
          else: {:error, :server_error}
    end
  end

  defp generate_user_code do
    for _ <- 1..@user_code_length, into: "" do
      <<Enum.random(@user_code_alphabet)>>
    end
  end

  @doc false
  @spec format_user_code(String.t()) :: String.t()
  def format_user_code(<<a::binary-size(4), b::binary-size(4)>>), do: a <> "-" <> b
  def format_user_code(code), do: code

  @doc false
  @spec normalize_user_code(String.t()) :: String.t()
  def normalize_user_code(input) when is_binary(input) do
    input |> String.upcase() |> String.replace(~r/[^A-Z]/, "")
  end

  @doc false
  @spec get_for_approval(Config.t(), String.t()) ::
          {:ok, DeviceGrant.t()} | {:error, :not_found}
  def get_for_approval(%Config{} = config, input) when is_binary(input) do
    now = DateTime.utc_now()
    code = normalize_user_code(input)

    from(g in DeviceGrant,
      where:
        g.user_code == ^code and is_nil(g.approved_at) and is_nil(g.denied_at) and
          is_nil(g.used_at) and g.expires_at > ^now
    )
    |> config.repo.one(Config.repo_opts(config))
    |> case do
      %DeviceGrant{} = grant -> {:ok, grant}
      nil -> {:error, :not_found}
    end
  end

  @doc false
  @spec approve(Config.t(), String.t(), binary(), keyword()) :: :ok | {:error, :not_found}
  def approve(%Config{} = config, input, subject, opts) when is_binary(subject) do
    decide(config, input, subject, [approved_at: Codes.now_s()], :device_approved, opts)
  end

  @doc false
  @spec deny(Config.t(), String.t(), binary(), keyword()) :: :ok | {:error, :not_found}
  def deny(%Config{} = config, input, subject, opts) when is_binary(subject) do
    decide(config, input, subject, [denied_at: Codes.now_s()], :device_denied, opts)
  end

  defp decide(config, input, subject, set, event, opts) do
    with {:ok, grant} <- get_for_approval(config, input) do
      from(g in DeviceGrant,
        where:
          g.id == ^grant.id and is_nil(g.approved_at) and is_nil(g.denied_at) and
            is_nil(g.used_at)
      )
      |> config.repo.update_all([set: [{:subject_id, subject} | set]], Config.repo_opts(config))
      |> case do
        {1, _} ->
          _ = config.host.audit(event, %{subject_id: subject, grant_id: grant.id}, opts)
          :ok

        {0, _} ->
          {:error, :not_found}
      end
    end
  end

  @doc false
  @spec poll(Config.t(), String.t(), keyword()) ::
          {:ok, %{access_token: String.t(), api_key: term()}} | {:error, atom()}
  def poll(%Config{} = config, device_code, opts) when is_binary(device_code) do
    now = Codes.now_s()

    case config.repo.get_by(
           DeviceGrant,
           [device_code_hash: Codes.hash(device_code)],
           Config.repo_opts(config)
         ) do
      nil ->
        {:error, :invalid_grant}

      %DeviceGrant{used_at: %DateTime{}} ->
        {:error, :invalid_grant}

      %DeviceGrant{denied_at: %DateTime{}} ->
        {:error, :access_denied}

      %DeviceGrant{} = grant ->
        if DateTime.compare(grant.expires_at, now) == :gt,
          do: poll_live(config, grant, now, opts),
          else: {:error, :expired_token}
    end
  end

  defp poll_live(config, %DeviceGrant{approved_at: nil} = grant, now, _opts) do
    threshold = DateTime.add(now, -(@device_interval_seconds - 1), :second)

    from(g in DeviceGrant,
      where: g.id == ^grant.id and (is_nil(g.last_polled_at) or g.last_polled_at <= ^threshold)
    )
    |> config.repo.update_all([set: [last_polled_at: now]], Config.repo_opts(config))
    |> case do
      {1, _} -> {:error, :authorization_pending}
      {0, _} -> {:error, :slow_down}
    end
  end

  # Approved but bound to nobody: the approval and the subject were written
  # in one conditional update, so this is a row edited by hand. Refuse it.
  defp poll_live(_config, %DeviceGrant{subject_id: nil}, _now, _opts),
    do: {:error, :invalid_grant}

  defp poll_live(config, %DeviceGrant{} = grant, now, opts) do
    # The host is asked before the grant is consumed, on purpose: a subject
    # the host no longer allows (suspended since approving, say) gets
    # access_denied and the grant stays approved, unconsumed. There is a
    # test for it.
    case config.host.subject_allowed?(grant.subject_id) do
      :ok -> consume_and_issue(config, grant, now, opts)
      {:error, _} -> {:error, :access_denied}
    end
  end

  defp consume_and_issue(config, grant, now, opts) do
    from(g in DeviceGrant, where: g.id == ^grant.id and is_nil(g.used_at))
    |> config.repo.update_all([set: [used_at: now]], Config.repo_opts(config))
    |> case do
      {0, _} ->
        {:error, :invalid_grant}

      {1, _} ->
        descriptor = %{type: :device, id: grant.id, client_id: nil, expires_at: nil}

        case config.host.issue_token(grant.subject_id, descriptor, opts) do
          {:ok, %{access_token: access_token, token: token}} ->
            {:ok, %{access_token: access_token, api_key: token}}

          {:error, _} ->
            {:error, :server_error}
        end
    end
  end

  @doc false
  @spec prune_expired(Config.t()) :: non_neg_integer()
  def prune_expired(%Config{} = config) do
    now = DateTime.utc_now()

    {count, _} =
      config.repo.delete_all(
        from(g in DeviceGrant, where: g.expires_at < ^now),
        Config.repo_opts(config)
      )

    count
  end
end
