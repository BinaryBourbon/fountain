defmodule Fountain.Repo.Migrations.AddSearch do
  @moduledoc """
  `GET /api/search` (#826): full-text search over conversation titles, turn
  prompts and assistant replies.

  `turns.reply_text` is the assistant's text for the turn — the `text`
  blocks of its log events, joined — materialised when the turn ends by
  `Fountain.Conversations._unsafe_update_turn/2`, so search reads a column
  and never re-parses `log_events` (and never indexes tool noise). Turns
  that ended before this migration have it null until
  `Fountain.Release.backfill_turn_replies/0` runs; the search covers their
  prompts either way.

  The three GIN indexes are on the exact expressions `Fountain.Search`
  queries; the search config is `simple` (no stemming, no stop words) so a
  hit is a hit for an identifier or a code fragment as much as for prose,
  and so a query in any language matches its own text.
  """
  use Ecto.Migration

  def up do
    alter table(:turns) do
      add :reply_text, :text
    end

    execute("""
    CREATE INDEX turns_prompt_search_idx ON turns
      USING gin (to_tsvector('simple', coalesce(prompt, '')))
    """)

    execute("""
    CREATE INDEX turns_reply_search_idx ON turns
      USING gin (to_tsvector('simple', coalesce(reply_text, '')))
    """)

    execute("""
    CREATE INDEX conversations_title_search_idx ON conversations
      USING gin (to_tsvector('simple', coalesce(title, '')))
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS conversations_title_search_idx")
    execute("DROP INDEX IF EXISTS turns_reply_search_idx")
    execute("DROP INDEX IF EXISTS turns_prompt_search_idx")

    alter table(:turns) do
      remove :reply_text
    end
  end
end
