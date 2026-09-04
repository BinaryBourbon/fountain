defmodule Fountain.Conversations.Reapply do
  @moduledoc """
  Re-selecting a conversation's Agent, Environment and Vault (#1565).

  A reapply keeps the conversation id, its turns and its transcript, and gives
  the row a fresh `configuration_generation`. Nothing moves the machine at
  that moment. The next prompt finds a conversation whose generation no longer
  matches the sandbox it names, provisions a replacement, and retires the old
  machine if it was this conversation's alone.

  ## The generation is the whole mechanism

  `configuration_generation` is an internal fifth leg of a persistent home's
  identity (`_unsafe_find_home/5`). An ordinary launch stays on the canonical
  `nil` generation, which is what makes three things true at once:

    * the home an agent identity owns is the `nil`-generation one, and every
      ordinary launch of that agent finds it again with its disk intact, so a
      reapply of one conversation must never destroy it (ADR 0023);
    * a reapplied conversation gets a private generation, so it can neither
      reset nor silently reuse the home its cotenants are still on;
    * a persistent machine on a private generation has exactly one holder and
      no launch can ever find it again, so it is retired with that
      conversation rather than kept the way a canonical home is.

  The replacement machine takes its mode from the newly selected agent, not
  from the machine it replaces. A reapply is the one operation that can change
  the agent, and the sandbox mode is the agent's to configure.

  ## Why a running server has to check for itself

  `Fountain.Conversations.reapply_conversation/3` stops the conversation's
  server first, so nothing is left holding the replaced machine. It finds that
  server through Horde's registry, which is a CRDT: a server on another node
  can be invisible for a beat (#800). `superseded?/2` is the definite answer,
  asked inside the server before it runs a turn. A server the detach missed
  therefore refuses the turn and stops, rather than quietly running it on the
  configuration the user replaced.
  """

  alias Fountain.Conversations
  alias Fountain.Conversations.Conversation

  @doc """
  Whether `sandbox_id` is no longer the machine `conv` wants.

  False for every conversation that has never been reapplied, because both
  generations are then `nil`. `_unsafe_`-shaped: the caller already owns
  `conv`, and `sandbox_id` is the machine it is holding.
  """
  @spec superseded?(binary() | nil, Conversation.t()) :: boolean()
  def superseded?(sandbox_id, %Conversation{} = conv) when is_binary(sandbox_id) do
    # ownership: the caller already holds `conv`, and `sandbox_id` is the
    # machine it is running on. Both belong to the same tenant by construction.
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      %{configuration_generation: generation} -> generation != conv.configuration_generation
      nil -> false
    end
  end

  def superseded?(_sandbox_id, _conv), do: false

  @doc """
  The reply a detach should give its caller.

  No live server is exactly what a detach asks for, so a server that exited
  between the registry lookup and the call succeeded rather than failed.
  """
  @spec detach_result(:ok | {:error, term()}) :: :ok | {:error, term()}
  def detach_result({:error, :not_running}), do: :ok
  def detach_result(other), do: other
end
