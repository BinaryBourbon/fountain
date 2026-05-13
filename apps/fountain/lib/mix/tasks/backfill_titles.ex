defmodule Mix.Tasks.Fountain.BackfillTitles do
  @shortdoc "Generate LLM titles for conversations that don't have one yet"
  @moduledoc """
  Iterates over all conversations that have a first turn but no title,
  loads per-user inference credentials, and calls TitleGenerator to
  populate the title field.

  ## Usage

      mix fountain.backfill_titles

  Runs in order of most-recently-created first. Safe to re-run —
  only processes conversations where title IS NULL.
  """

  use Mix.Task

  alias Fountain.{Conversations, Crypto, InferenceCredentials}

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    import Ecto.Query

    alias Fountain.Conversations.{Conversation, Turn}
    alias Fountain.Repo

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
      rows
      |> Enum.with_index(1)
      |> Enum.reduce(%{}, fn {{conv_id, user_id, prompt}, idx}, cache ->
        IO.write("[#{idx}/#{total}] conv #{String.slice(conv_id, 0, 8)}... ")

        {cache, creds} =
          case Map.fetch(cache, user_id) do
            {:ok, val} -> {cache, val}
            :error ->
              val = load_credentials(user_id)
              {Map.put(cache, user_id, val), val}
          end

        case creds do
          {:error, reason} ->
            IO.puts("SKIP (credentials unavailable: #{inspect(reason)})")

          {:ok, inference_creds} ->
            case Fountain.Conversations.TitleGenerator.generate(prompt, inference_creds) do
              {:ok, title} ->
                conv = Conversations._unsafe_get_conversation!(conv_id)
                {:ok, _} = Conversations.update_conversation(conv, %{title: title})
                IO.puts("OK \"#{title}\"")

              {:error, reason} ->
                IO.puts("FAIL (#{inspect(reason)})")
            end
        end

        cache
      end)

      IO.puts("\nDone.")
    end
  end

  defp load_credentials(user_id) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id),
         {:ok, creds} <- InferenceCredentials.decrypted_for_user(user_id, dek) do
      {:ok, creds}
    end
  end
end
