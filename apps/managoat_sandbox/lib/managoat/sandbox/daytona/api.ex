defmodule Managoat.Sandbox.Daytona.Api do
  @moduledoc """
  Daytona control-plane client (`app.daytona.io/api`, or a self-hosted
  instance via `DAYTONA_API_URL`).

  Daytona sandboxes are genuinely name-addressable — API paths accept the
  name Fountain mints — so no metadata emulation is needed; a `fountain`
  label is stamped anyway so listings can filter to our sandboxes.

  Sandboxes are created with `autoStopInterval: 0` and `ttlMinutes: 0`:
  Fountain's own lifecycle owns suspension (an agent turn must be
  unbounded, and a platform auto-stop mid-turn would look like a crash),
  and `autoArchiveInterval` moves long-parked filesystems to object
  storage so a suspended sandbox stops consuming disk quota.
  """

  # Days a stopped sandbox keeps its disk before archiving to object
  # storage (Daytona takes minutes). Archived sandboxes still start —
  # just slower — so ADR 0017's never-aged-out promise holds.
  @auto_archive_minutes 7 * 24 * 60

  def req do
    Req.new(
      [
        base_url: base_url(),
        auth: {:bearer, api_key!()},
        receive_timeout:
          Managoat.Sandbox.Config.get(Managoat.Sandbox.Daytona, :timeout_ms, 30_000)
      ] ++ Managoat.Sandbox.Config.get(Managoat.Sandbox.Daytona, :req_options, [])
    )
  end

  def base_url,
    do:
      Managoat.Sandbox.Config.get(
        Managoat.Sandbox.Daytona,
        :api_url,
        "https://app.daytona.io/api"
      )

  def api_key! do
    Managoat.Sandbox.Config.get(Managoat.Sandbox.Daytona, :api_key) ||
      raise "DAYTONA_API_KEY is not set — cannot talk to daytona.io"
  end

  @doc """
  The snapshot (image) new sandboxes are created from, or nil for the
  organization's default. A named snapshot must be registered with the org
  (the API rejects unknown ones with a 400).
  """
  def snapshot do
    Managoat.Sandbox.Config.get(Managoat.Sandbox.Daytona, :snapshot)
  end

  def create_sandbox(name) do
    base = %{
      name: name,
      labels: %{fountain: "1"},
      autoStopInterval: 0,
      autoArchiveInterval: @auto_archive_minutes,
      ttlMinutes: 0
    }

    body =
      case snapshot() do
        nil -> base
        snapshot -> Map.put(base, :snapshot, snapshot)
      end

    case Req.post(req(), url: "/sandbox", json: body) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_sandbox(name) do
    case Req.get(req(), url: "/sandbox/#{name}") do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: 404, body: _}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_sandbox(name) do
    case Req.delete(req(), url: "/sandbox/#{name}") do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def stop(name), do: lifecycle_post(name, "stop")
  def start(name), do: lifecycle_post(name, "start")

  defp lifecycle_post(name, action) do
    case Req.post(req(), url: "/sandbox/#{name}/#{action}", json: %{}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Every fountain-labeled sandbox name, cursor-paginated. Refuses a partial view."
  def list_all_names(max_pages \\ 40) do
    collect_names(nil, MapSet.new(), 0, max_pages)
  end

  defp collect_names(_cursor, _acc, page, max_pages) when page >= max_pages do
    {:error, :truncated}
  end

  defp collect_names(cursor, acc, page, max_pages) do
    params =
      [labels: Jason.encode!(%{fountain: "1"}), limit: 100] ++
        if cursor, do: [cursor: cursor], else: []

    case Req.get(req(), url: "/sandbox", params: params) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {items, next} = page_items(body)

        acc =
          Enum.reduce(items, acc, fn sandbox, set ->
            case sandbox["name"] do
              name when is_binary(name) -> MapSet.put(set, name)
              _ -> set
            end
          end)

        if next in [nil, ""] do
          {:ok, acc}
        else
          collect_names(next, acc, page + 1, max_pages)
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp page_items(%{"items" => items} = body) when is_list(items),
    do: {items, body["nextCursor"] || body["cursor"]}

  defp page_items(items) when is_list(items), do: {items, nil}
  defp page_items(_body), do: {[], nil}

  @doc """
  Replace the sandbox's egress policy on the runner. Block-all plus a
  domain allowlist — genuinely default-deny, so `allow: []` needs no
  translation.
  """
  def set_network(name, allow_domains) do
    # The API takes the allowlist as a comma-separated string (measured
    # live: an array answers 400 "domainAllowList must be a string").
    body = %{networkBlockAll: true, domainAllowList: Enum.join(allow_domains, ",")}

    case Req.post(req(), url: "/sandbox/#{name}/network-settings", json: body) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The per-sandbox toolbox base URL: the account's proxy URL with the
  sandbox's server-assigned **id** appended (`{proxy}/{id}` — the DTO's
  `toolboxProxyUrl` alone carries no sandbox identity; the official SDK
  builds exactly this base).
  """
  def toolbox_url(name) do
    with {:ok, info} <- get_sandbox(name),
         {:ok, proxy} <- proxy_url(info) do
      {:ok, String.trim_trailing(proxy, "/") <> "/" <> info["id"]}
    end
  end

  defp proxy_url(info) do
    case info["toolboxProxyUrl"] do
      url when is_binary(url) and url != "" ->
        {:ok, url}

      _ ->
        case Req.get(req(), url: "/sandbox/#{info["id"]}/toolbox-proxy-url") do
          {:ok, %{status: 200, body: %{"url" => url}}} -> {:ok, url}
          {:ok, %{status: 200, body: url}} when is_binary(url) -> {:ok, url}
          {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
