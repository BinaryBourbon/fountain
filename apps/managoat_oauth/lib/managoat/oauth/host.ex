defmodule Managoat.OAuth.Host do
  @moduledoc """
  What the platform running `Managoat.OAuth` supplies: everything the grant
  state machine needs to know about subjects, tokens and the record it
  leaves, and nothing about grants.

    * `c:subject_allowed?/1` — may this subject collect a token right now?
      Asked by `poll_device_grant` **before** the grant is consumed, so a
      subject the host has suspended (or one whose approval predates a
      change of state) is refused with `{:error, :access_denied}` and the
      grant is left approved and unconsumed. The code exchange does not ask:
      the consent that issued the code was the host's check.
    * `c:issue_token/3` — mint the token for a consumed grant. `grant` says
      which kind and what the library decided about it:

          %{type: :authorization_code, id: code_id, client_id: "spa", expires_at: %DateTime{}}
          %{type: :device, id: grant_id, client_id: nil, expires_at: nil}

      `expires_at` is the library's token lifetime for that grant (thirty
      days for a code, none for a device grant); a host honours it. Returns
      `{:ok, %{access_token: raw, token: anything}}`: `access_token` is the
      bearer string the client receives, `token` is whatever the host wants
      handed back to its own caller (Fountain puts its `%ApiKey{}` there).
      Any `{:error, _}` becomes `{:error, :server_error}` to the caller. For
      a code the grant is already consumed when this is called; see the
      `Managoat.OAuth` moduledoc for why.
    * `c:audit/3` — a mutation happened. `event` is one of `:authorized`
      (a code was issued; `meta` has `subject_id`, `client_id`,
      `redirect_uri`), `:device_approved` and `:device_denied` (`meta` has
      `subject_id` and `grant_id`). The library cannot complete any of
      these three mutations without calling this, which is what lets a host
      say its OAuth mutations are audited by construction. Return `:ok`; a
      host that wants recording to be best-effort rescues inside.

  `subject` is an opaque binary throughout: the library stores it, hands it
  back, and never joins it to anything. `opts` is the keyword list the
  host's own caller passed to the instance function, untouched, so
  attribution (an actor, a request IP) travels from the host's web layer to
  the host's audit trail without the library reading it.
  """

  @type subject :: binary()
  @type event :: :authorized | :device_approved | :device_denied
  @type grant :: %{
          type: :authorization_code | :device,
          id: binary(),
          client_id: String.t() | nil,
          expires_at: DateTime.t() | nil
        }

  @callback subject_allowed?(subject) :: :ok | {:error, reason :: atom()}
  @callback issue_token(subject, grant, opts :: keyword()) ::
              {:ok, %{access_token: String.t(), token: term()}} | {:error, term()}
  @callback audit(event, meta :: map(), opts :: keyword()) :: :ok
end
