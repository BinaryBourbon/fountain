defmodule Fountain.Upgrader do
  @moduledoc false

  require Logger

  alias Fountain.{GithubReleases, UpdateChecker}

  @asset_name "aod-server-linux-x86_64"

  @doc "Perform self-upgrade. Returns :ok, {:error, :no_update}, or {:error, reason}."
  def perform do
    case UpdateChecker.get_status() do
      %{has_update: false} ->
        {:error, :no_update}

      _ ->
        do_upgrade()
    end
  end

  @doc "Schedule a server restart after 500ms. Extracted for testability."
  def schedule_restart do
    spawn(fn -> Process.sleep(500); :init.stop(0) end)
  end

  @doc "Path to the running server binary. Override via AOD_BINARY_PATH env var."
  def exe_path do
    System.get_env("AOD_BINARY_PATH") ||
      System.get_env("RELEASE_BIN") ||
      (System.argv() |> hd())
  end

  defp do_upgrade do
    target = exe_path()
    tmp = target <> ".new"

    with {:ok, release} <- GithubReleases.get_latest_release(),
         {:ok, asset} <- GithubReleases.find_asset(release, @asset_name),
         :ok <- GithubReleases.download_asset(asset, tmp),
         :ok <- File.chmod(tmp, 0o755),
         :ok <- File.rename(tmp, target) do
      Logger.info("Upgrader: binary swapped to #{release["tag_name"]}, restarting")
      :ok
    else
      {:error, reason} ->
        Logger.error("Upgrader: upgrade failed — #{inspect(reason)}")
        File.rm(tmp)
        {:error, reason}
    end
  end
end
