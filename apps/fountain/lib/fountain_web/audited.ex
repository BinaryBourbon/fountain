defmodule FountainWeb.Audited do
  @moduledoc """
  Records audit events from controllers and LiveViews.

  Auditing used to live entirely in a plug on the `:api` pipeline, so the whole
  browser surface was invisible: creating, changing or deleting a **secret**
  through the UI produced no record at all, while the same secret written
  through the API produced one. For a product whose job is holding tenant
  secrets, that is the wrong way round.

  ## Actor

  `actor` was hardcoded to `"api"`, which made a human, a CI job and an agent
  running inside a sandbox indistinguishable in the trail. It is now derived:

    * `"sprite"` — a per-conversation callback token (see the scopes added for
      the sandbox privilege-escalation fix). Worth separating: "the agent did
      this" and "the account owner did this" are very different claims.
    * `"api"` — any other bearer token
    * `"ui"` — a browser session
    * `"system"` — no identifiable actor

  Recording is best-effort throughout: `Fountain.Audit.record/1` rescues, so a
  logging failure can never break the operation being logged.
  """

  alias Fountain.Accounts.ApiKey
  alias Fountain.Audit

  @doc """
  Record an event originating from a `Plug.Conn`.

      Audited.from_conn(conn, "auth.login", "session", metadata: %{"result" => "ok"})

  Pass `:actor` explicitly where the connection cannot reveal it — at login the
  session does not exist yet, so derivation would report `"system"` for what is
  plainly a browser sign-in.
  """
  def from_conn(conn, action, resource_type, opts \\ []) do
    Audit.record(%{
      action: action,
      resource_type: resource_type,
      resource_id: Keyword.get(opts, :resource_id),
      actor: Keyword.get(opts, :actor) || conn_actor(conn),
      request_ip: format_ip(conn.remote_ip),
      metadata: Keyword.get(opts, :metadata, %{}),
      user_id: Keyword.get(opts, :user_id) || conn_user_id(conn)
    })
  end

  @doc """
  Record an event originating from a LiveView socket.

      Audited.from_socket(socket, "vault.secret.write", "vault_secret", resource_id: key)
  """
  def from_socket(socket, action, resource_type, opts \\ []) do
    Audit.record(%{
      action: action,
      resource_type: resource_type,
      resource_id: Keyword.get(opts, :resource_id),
      actor: "ui",
      request_ip: socket.assigns[:client_ip],
      metadata: Keyword.get(opts, :metadata, %{}),
      user_id: Keyword.get(opts, :user_id) || socket_user_id(socket)
    })
  end

  @doc """
  The `:actor` / `:request_ip` pair for a context function that audits itself.

      Accounts.create_api_key(user.id, name, Audited.attribution(conn))

  `from_conn/4` and `from_socket/4` record on behalf of a web surface. This is
  for the other direction: the mutation is audited inside the context (so UI,
  API and system callers are covered alike) and the caller supplies only what
  the context cannot know — who was on the other end of the request.

  Pass overrides where the connection cannot reveal the actor. `POST
  /api/auth/token` runs on the `:api_public` pipeline, so nothing has assigned
  `:current_user` yet and derivation would report `"system"` for what is
  plainly a CLI sign-in — the same caveat `from_conn/4` carries for login.
  """
  def attribution(conn_or_socket, overrides \\ [])

  def attribution(%Plug.Conn{} = conn, overrides) do
    Keyword.merge([actor: conn_actor(conn), request_ip: format_ip(conn.remote_ip)], overrides)
  end

  def attribution(%Phoenix.LiveView.Socket{} = socket, overrides) do
    Keyword.merge([actor: "ui", request_ip: socket.assigns[:client_ip]], overrides)
  end

  @doc """
  Resolve the client address for a LiveView socket at mount.

  `get_connect_info/2` is only callable during mount, so the result is stashed
  in assigns for later events. Forwarded headers are honoured only when the peer
  is a configured proxy — the same rule the HTTP path uses, and for the same
  reason: trusting a header from a direct client lets it write whatever address
  it likes into the audit trail.
  """
  def put_client_ip(socket) do
    Phoenix.Component.assign(socket, :client_ip, resolve_client_ip(socket))
  end

  defp resolve_client_ip(socket) do
    peer = Phoenix.LiveView.get_connect_info(socket, :peer_data)
    headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []

    case peer do
      %{address: address} ->
        # Delegates the whole rule — peer gate AND header walk — to the HTTP
        # path's implementation. A previous copy here parsed x-forwarded-for
        # itself and took the leftmost (client-supplied) entry, so UI audit
        # rows and API audit rows disagreed whenever the chain had more than
        # one hop.
        address
        |> FountainWeb.Plugs.ClientIp.resolve_address(headers)
        |> format_ip()

      _ ->
        nil
    end
  end

  defp conn_actor(conn) do
    case conn.assigns[:current_api_key] do
      %ApiKey{scopes: scopes} ->
        if "sprite" in scopes, do: "sprite", else: "api"

      _ ->
        if conn.assigns[:current_user], do: "ui", else: "system"
    end
  end

  defp conn_user_id(conn) do
    case conn.assigns[:current_user] do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp socket_user_id(socket) do
    case socket.assigns[:current_user] do
      %{id: id} -> id
      _ -> socket.assigns[:user_id]
    end
  end

  defp format_ip(nil), do: nil
  defp format_ip(tuple) when is_tuple(tuple), do: tuple |> :inet.ntoa() |> to_string()
  defp format_ip(other), do: to_string(other)
end
