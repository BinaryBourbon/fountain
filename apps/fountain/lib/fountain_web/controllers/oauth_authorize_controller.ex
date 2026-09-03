defmodule FountainWeb.OAuthAuthorizeController do
  @moduledoc """
  The consent page of Fountain's OAuth 2.0 authorization server (#818):
  `GET /oauth/authorize` shows which registered app is asking; `POST` with
  the decision either issues a one-time code and redirects to the app's
  registered URI, or redirects there with `error=access_denied`.

  Browser route with the session and CSRF protection. Not signed in →
  remember this request and go to login; the login round-trips back here.
  A request whose client or redirect URI does not check out is **rendered**
  as an error, never redirected — see `Fountain.OAuth.validate_request/2`.
  That includes a development-mode client requested by anyone but its owner.
  """
  use FountainWeb, :controller

  alias Fountain.OAuth
  alias FountainWeb.ReturnTo

  plug :put_layout, false
  plug :require_user

  def show(conn, params) do
    case OAuth.validate_request(params, conn.assigns.current_user.id) do
      {:ok, client} ->
        conn
        |> allow_redirect_form_action(params["redirect_uri"])
        |> render(:consent, client: client, params: request_params(params), error: nil)

      {:error, reason} ->
        conn |> put_status(:bad_request) |> render(:invalid, reason: reason)
    end
  end

  def create(conn, %{"decision" => decision} = params) do
    user = conn.assigns.current_user

    case OAuth.validate_request(params, user.id) do
      {:ok, _client} when decision == "allow" ->
        conn = allow_redirect_form_action(conn, params["redirect_uri"])

        case OAuth.authorize(user.id, params, FountainWeb.Audited.attribution(conn)) do
          {:ok, code} ->
            redirect(conn,
              external:
                with_query(params["redirect_uri"], %{"code" => code, "state" => params["state"]})
            )

          {:error, _} ->
            conn |> put_status(:internal_server_error) |> render(:invalid, reason: :server_error)
        end

      {:ok, _client} ->
        conn
        |> allow_redirect_form_action(params["redirect_uri"])
        |> redirect(
          external:
            with_query(params["redirect_uri"], %{
              "error" => "access_denied",
              "state" => params["state"]
            })
        )

      {:error, reason} ->
        conn |> put_status(:bad_request) |> render(:invalid, reason: reason)
    end
  end

  def create(conn, params), do: create(conn, Map.put(params, "decision", "deny"))

  defp request_params(params),
    do:
      Map.take(
        params,
        ~w(client_id redirect_uri code_challenge code_challenge_method state scope)
      )

  defp with_query(uri, extra) do
    parsed = URI.parse(uri)
    existing = if parsed.query, do: URI.decode_query(parsed.query), else: %{}

    query =
      existing |> Map.merge(Map.reject(extra, fn {_, v} -> is_nil(v) end)) |> URI.encode_query()

    URI.to_string(%{parsed | query: query})
  end

  # The base browser CSP is `form-action 'self'`; a successful consent POST
  # redirects the browser to the app's own origin, which Chrome enforces
  # form-action against on the redirect. Widen it only to this request's
  # validated redirect origin (#818, narrowed in #1125). The requested URI is
  # important for RFC 8252 loopback redirects, whose port may vary.
  defp allow_redirect_form_action(conn, redirect_uri) do
    origins = Enum.join(["'self'" | OAuth.form_action_origins(redirect_uri)], " ")

    update_resp_header(conn, "content-security-policy", "", fn csp ->
      if String.contains?(csp, "form-action"),
        do: Regex.replace(~r/form-action[^;]*/, csp, "form-action #{origins}"),
        else: csp <> "; form-action #{origins}"
    end)
  end

  # `:browser_optional_auth` loaded the user if there is a session; without
  # one, stash this request and send them to sign in.
  defp require_user(conn, _opts) do
    case conn.assigns[:current_user] do
      %{email_verified_at: verified} = user when not is_nil(user) and not is_nil(verified) ->
        conn

      _ ->
        conn
        |> ReturnTo.stash()
        |> redirect(to: ~p"/auth/login")
        |> halt()
    end
  end
end
