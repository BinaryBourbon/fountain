defmodule Fountain.PlatformChatGPT.Device do
  @moduledoc """
  The device-code Connect from `/admin/inference` (ADR 0047 gate 3), run
  from the server so an admin needs no laptop-side codex install.

  `start/1` runs the three legs in a supervised task
  (`Task.Supervisor.start_child/2`, never `Task.async`: nothing awaits it,
  and a crash must not take the admin's LiveView down) and reports to the
  process that asked, as `{:platform_chatgpt_device, message}`:

    * `{:code, %{verification_url, user_code}}` — show these; the admin
      approves the code on the page.
    * `{:connected, status}` — the grant is stored;
      `Fountain.PlatformChatGPT.status/0` is what came back.
    * `{:error, reason}` — the flow failed or the fifteen minutes ran out.

  Codex polls at the interval the server returns for at most fifteen
  minutes; so does this.
  """

  alias Fountain.PlatformChatGPT
  alias Fountain.PlatformChatGPT.OAuth

  @poll_deadline_ms 15 * 60 * 1_000

  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts) do
    notify = Keyword.fetch!(opts, :notify)
    actor_user_id = Keyword.get(opts, :actor_user_id)

    Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
      run(notify, actor_user_id)
    end)
  end

  @doc false
  def run(notify, actor_user_id) do
    with {:ok, started} <- OAuth.device_start(),
         :ok <-
           send_to(notify, {:code, Map.take(started, [:verification_url, :user_code])}),
         {:ok, grant} <- poll(started, System.monotonic_time(:millisecond) + @poll_deadline_ms),
         {:ok, tokens} <- OAuth.device_exchange(grant),
         {:ok, _account} <-
           PlatformChatGPT.connect_from_tokens(tokens, "device_code",
             actor_user_id: actor_user_id
           ) do
      send_to(notify, {:connected, PlatformChatGPT.status()})
    else
      {:error, reason} -> send_to(notify, {:error, reason})
    end
  end

  defp poll(%{device_auth_id: id, user_code: code, interval: interval} = started, deadline) do
    case OAuth.device_poll(id, code) do
      {:ok, grant} ->
        {:ok, grant}

      :pending ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :device_timeout}
        else
          Process.sleep(interval * 1_000)
          poll(started, deadline)
        end

      {:error, _} = error ->
        error
    end
  end

  defp send_to(pid, message) do
    send(pid, {:platform_chatgpt_device, message})
    :ok
  end
end
