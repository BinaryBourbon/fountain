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
    # 1. Evaluate runtime.exs so env-based config (MASTER_SECRETS_KEY, etc.)
    #    is applied. DATABASE_URL is only wired to the Repo in runtime.exs
    #    when PHX_SERVER=1, so we configure it manually in step 2.
    Mix.Task.run("app.config")

    # 2. Configure Repo directly from DATABASE_URL — runtime.exs skips this
    #    block when running outside the server (no PHX_SERVER env var).
    database_url =
      System.get_env("DATABASE_URL") ||
        raise "DATABASE_URL environment variable is not set"

    Application.put_env(:fountain, Fountain.Repo,
      url: database_url,
      pool_size: 2,
      ssl: true,
      ssl_opts: [verify: :verify_none]
    )

    # 3. Suppress the HTTP listener so we don't fight the running server for
    #    port 10000. The endpoint is supervised under the :fountain app.
    endpoint_config = Application.get_env(:fountain, FountainWeb.Endpoint, [])
    Application.put_env(:fountain, FountainWeb.Endpoint, Keyword.put(endpoint_config, :server, false))

    # 4. Start the OTP app (Repo, PubSub, Horde, etc.) but not the HTTP listener.
    {:ok, _} = Application.ensure_all_started(:fountain)

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
      _cache =
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
    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      InferenceCredentials.decrypted_for_user(user_id, dek)
    end
  end
end
