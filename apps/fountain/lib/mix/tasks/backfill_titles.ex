defmodule Mix.Tasks.Fountain.BackfillTitles do
  @shortdoc "Generate LLM titles for conversations that don't have one yet"
  @moduledoc """
  Iterates over all conversations that have a first turn but no title,
  loads per-user inference credentials, and calls TitleGenerator to
  populate the title field.

  ## Usage

      mix fountain.backfill_titles

  Runs in batches of 50, prints progress to stdout. Safe to re-run —
  only processes conversations where title IS NULL.
  """

  use Mix.Task

  require Logger

  @batch_size 50

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    import Ecto.Query

    alias Fountain.{Conversations, Crypto, InferenceCredentials, Repo}
    alias Fountain.Conversations.{Conversation, Turn}

    # Load all conversation IDs + user IDs that have a first-turn prompt but no title.
    rows =
      Repo.all(
        from c in Conversation,
          join: t in Turn,
          on: t.conversation_id == c.id and t.turn_number == 1,
          where: is_nil(c.title) and not is_nil(t.prompt) and t.prompt != "",
          select: {c.id, c.user_id, t.prompt},
          order_by: [desc: c.inserted_at]
      )

    total = length(rows)
    IO.puts("Found #{total} conversations without a title.")

    if total == 0 do
      IO.puts("Nothing to do.")
    else
      # Cache credentials per user so we only decrypt once per user.
      cred_cache = %{}

      rows
      |> Enum.with_index(1)
      |> Enum.reduce(cred_cache, fn {{conv_id, user_id, prompt}, idx}, cache ->
        IO.write("[#{idx}/#{total}] conv #{String.slice(conv_id, 0, 8)}... ")

        {cache, creds} =
          case Map.fetch(cache, user_id) do
            {:ok, val} ->
              {cache, val}

            :error ->
              val = load_credentials(user_id, Crypto)
              {Map.put(cache, user_id, val), val}
          end

        case creds do
          {:error, reason} ->
            IO.puts("SKIP (credentials unavailable: #{inspect(reason)})")
            cache

          {:ok, inference_creds} ->
            case Fountain.Conversations.TitleGenerator.generate(prompt, inference_creds) do
              {:ok, title} ->
                conv = Conversations._unsafe_get_conversation!(conv_id)
                {:ok, _} = Conversations.update_conversation(conv, %{title: title})
                IO.puts("OK \"#{title}\"")

              {:error, reason} ->
                IO.puts("FAIL (#{inspect(reason)})")
            end

            cache
        end
      end)

      IO.puts("\nDone.")
    end
  end

  defp load_credentials(user_id, crypto_mod) do
    with {:ok, dek} <- crypto_mod.load_tenant_key(user_id),
         {:ok, creds} <- InferenceCredentials.decrypted_for_user(user_id, dek) do
      {:ok, creds}
    end
  end
end
