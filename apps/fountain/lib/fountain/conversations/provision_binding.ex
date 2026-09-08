defmodule Fountain.Conversations.ProvisionBinding do
  @moduledoc """
  Hold a fresh wake's actor until its destination binding commits.

  Horde still arbitrates the child before the holder transaction. This bounded
  wait prevents provisioning in that gap. It is not an actor lease or a prompt
  receipt; startup rechecks the binding under its execution locks afterward.
  """
  alias Fountain.Repo
  alias Fountain.Conversations.{Conversation, Sandbox}

  def _unsafe_await(conversation_id, sandbox_id, source_id) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await(conversation_id, sandbox_id, source_id, deadline)
  end

  defp await(conversation_id, sandbox_id, source_id, deadline) do
    parent = Repo.get(Conversation, conversation_id)
    sandbox = Repo.get(Sandbox, sandbox_id)

    cond do
      is_nil(parent) or is_nil(sandbox) or parent.user_id != sandbox.user_id ->
        {:error, :ownership_changed}

      parent.sandbox_id == sandbox.id ->
        :ok

      parent.sandbox_id != source_id or sandbox.status != "pending" ->
        {:error, :ownership_changed}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :binding_timeout}

      true ->
        Process.sleep(50)
        await(conversation_id, sandbox_id, source_id, deadline)
    end
  end
end
