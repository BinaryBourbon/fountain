defmodule Fountain.UpdateChecker do
  @moduledoc false

  use GenServer
  require Logger

  alias Fountain.GithubReleases

  @pubsub Fountain.PubSub
  @topic "update_checker"
  @check_interval :timer.hours(1)

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Trigger an immediate release check asynchronously."
  def check_now(server \\ __MODULE__) do
    GenServer.cast(server, :check_now)
  end

  @doc "Return the current update status synchronously."
  def get_status(server \\ __MODULE__) do
    GenServer.call(server, :get_status)
  end

  @impl true
  def init(opts) do
    release_fetcher = Keyword.get(opts, :release_fetcher, &GithubReleases.get_latest_release/0)

    state = %{
      current_version: read_current_version(),
      latest_version: nil,
      has_update: false,
      last_checked_at: nil,
      checking: false,
      release_fetcher: release_fetcher
    }

    send(self(), :check)
    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    state = %{state | checking: true}
    broadcast(state)
    new_state = do_check(state)
    Process.send_after(self(), :check, @check_interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:check_now, state) do
    send(self(), :check)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, Map.delete(state, :release_fetcher), state}
  end

  defp do_check(state) do
    case state.release_fetcher.() do
      {:ok, release} ->
        latest = release["tag_name"] |> String.trim_leading("v")
        has_update = version_newer?(latest, state.current_version)

        new_state = %{
          state
          | latest_version: latest,
            has_update: has_update,
            last_checked_at: DateTime.utc_now(),
            checking: false
        }

        broadcast(new_state)
        new_state

      {:error, reason} ->
        Logger.warning("UpdateChecker: failed to check for updates: #{inspect(reason)}")
        new_state = %{state | checking: false, last_checked_at: DateTime.utc_now()}
        broadcast(new_state)
        new_state
    end
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:update_status, Map.delete(state, :release_fetcher)})
  end

  defp read_current_version do
    case :application.get_key(:fountain, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end

  defp version_newer?(latest, current) do
    with {:ok, l} <- Version.parse(latest),
         {:ok, c} <- Version.parse(current) do
      Version.compare(l, c) == :gt
    else
      _ -> false
    end
  end
end
