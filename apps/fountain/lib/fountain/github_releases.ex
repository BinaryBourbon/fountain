defmodule Fountain.GithubReleases do
  @moduledoc false

  @repo "jhgaylor/aod-ex"
  @api_base "https://api.github.com"
  @headers [{"Accept", "application/vnd.github.v3+json"}, {"User-Agent", "aod-ex"}]

  def get_latest_release(repo \\ @repo) do
    url = "#{@api_base}/repos/#{repo}/releases/latest"

    case Req.get(url, headers: @headers) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  def find_asset(release, asset_name) do
    assets = Map.get(release, "assets", [])

    case Enum.find(assets, fn a -> a["name"] == asset_name end) do
      nil -> {:error, :not_found}
      asset -> {:ok, asset}
    end
  end

  def download_asset(asset, dest_path) do
    url = asset["url"]
    headers = [{"Accept", "application/octet-stream"}, {"User-Agent", "aod-ex"}]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} -> File.write(dest_path, body)
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
