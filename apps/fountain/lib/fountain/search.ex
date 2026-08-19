defmodule Fountain.Search do
  @moduledoc """
  Full-text search across a user's conversations (#826): titles, turn
  prompts and assistant replies, for a client's command palette — "jump to
  the message".

  Postgres full-text, `simple` config (no stemming, no stop words: an
  identifier or a code fragment matches as itself, and so does text in any
  language), `websearch_to_tsquery` syntax (`quoted phrases`, `-excluded`,
  `or`). Three sources, one shape:

    * `title` — a conversation's title (`Conversations.title`);
    * `prompt` — a turn's prompt;
    * `reply` — a turn's assistant text, from `turns.reply_text`, which is
      materialised when the turn ends (`Conversations._unsafe_update_turn/2`).
      A turn in flight is not searchable by its reply until it ends; turns
      that ended before the column existed need
      `Fountain.Release.backfill_turn_replies/0`.

  Every source is scoped by `user_id` in the query itself; there is no
  unscoped entry point. Hits are ranked (`ts_rank`, then newest first) and
  paged with `limit` / `offset` — one query per source, merged here, so a
  page costs three indexed lookups; fine at the sizes a tenant has.
  """

  import Ecto.Query, warn: false

  alias Fountain.Conversations.{Conversation, Turn}
  alias Fountain.Repo

  @default_limit 20
  @max_limit 100
  @snippet_words 32
  @kinds ~w(title prompt reply)

  @typedoc "One hit; `turn_id` is nil for a `title` hit."
  @type hit :: %{
          kind: String.t(),
          conversation_id: String.t(),
          agent_id: String.t() | nil,
          turn_id: String.t() | nil,
          turn_number: non_neg_integer() | nil,
          snippet: String.t(),
          ts: DateTime.t(),
          rank: float()
        }

  @doc "Every `kind` a hit can have — the wire enum."
  def kinds, do: @kinds

  @doc "The page-size cap."
  def max_limit, do: @max_limit

  @doc """
  Search `user_id`'s conversations for `q`.

  Options: `:limit` (default #{@default_limit}, capped at #{@max_limit}),
  `:offset` (default 0), `:agent_id`, `:conversation_id`, `:since` (a
  `DateTime`; hits at or after it), `:kinds` (a subset of `#{inspect(@kinds)}`).

  Returns `%{hits: [hit], has_more: boolean, limit: n, offset: n}`. A blank
  query, or one with no searchable term (`"-only"`), matches nothing.
  """
  @spec search(String.t(), String.t(), keyword()) :: %{
          hits: [hit()],
          has_more: boolean(),
          limit: pos_integer(),
          offset: non_neg_integer()
        }
  def search(user_id, q, opts \\ []) when is_binary(user_id) and is_binary(q) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp(1, @max_limit)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    kinds = Keyword.get(opts, :kinds) || @kinds
    q = String.trim(q)

    hits =
      if q == "" or not positive_term?(q) do
        []
      else
        # Each source returns at most one page past the offset; the merge
        # below re-ranks across sources and re-applies the window.
        take = offset + limit + 1

        kinds
        |> Enum.flat_map(fn
          "title" -> title_hits(user_id, q, take, opts)
          "prompt" -> turn_hits(user_id, q, :prompt, take, opts)
          "reply" -> turn_hits(user_id, q, :reply_text, take, opts)
          _ -> []
        end)
        |> Enum.sort_by(&{-&1.rank, DateTime.to_unix(&1.ts, :microsecond) * -1, &1.kind})
        |> Enum.drop(offset)
        |> Enum.take(limit + 1)
      end

    %{
      hits: Enum.take(hits, limit),
      has_more: length(hits) > limit,
      limit: limit,
      offset: offset
    }
  end

  # ── sources ─────────────────────────────────────────────────────────────

  defp title_hits(user_id, q, take, opts) do
    from(c in Conversation,
      where: c.user_id == ^user_id and not is_nil(c.title),
      where:
        fragment(
          "to_tsvector('simple', coalesce(?, '')) @@ websearch_to_tsquery('simple', ?)",
          c.title,
          ^q
        ),
      select: %{
        kind: "title",
        conversation_id: c.id,
        agent_id: c.agent_id,
        turn_id: nil,
        turn_number: nil,
        snippet:
          fragment(
            "ts_headline('simple', ?, websearch_to_tsquery('simple', ?), ?)",
            c.title,
            ^q,
            ^headline_opts()
          ),
        ts: c.inserted_at,
        rank:
          fragment(
            "ts_rank(to_tsvector('simple', coalesce(?, '')), websearch_to_tsquery('simple', ?))",
            c.title,
            ^q
          )
      },
      order_by: [
        desc:
          fragment(
            "ts_rank(to_tsvector('simple', coalesce(?, '')), websearch_to_tsquery('simple', ?))",
            c.title,
            ^q
          ),
        desc: c.inserted_at
      ],
      limit: ^take
    )
    |> filter_conversation(opts)
    |> filter_since(:c, opts)
    |> Repo.all()
  end

  defp turn_hits(user_id, q, field, take, opts) do
    kind = if field == :prompt, do: "prompt", else: "reply"

    from(t in Turn,
      join: c in Conversation,
      on: c.id == t.conversation_id,
      as: :conv,
      where: c.user_id == ^user_id,
      where:
        fragment(
          "to_tsvector('simple', coalesce(?, '')) @@ websearch_to_tsquery('simple', ?)",
          field(t, ^field),
          ^q
        ),
      select: %{
        kind: ^kind,
        conversation_id: c.id,
        agent_id: c.agent_id,
        turn_id: t.id,
        turn_number: t.turn_number,
        snippet:
          fragment(
            "ts_headline('simple', ?, websearch_to_tsquery('simple', ?), ?)",
            field(t, ^field),
            ^q,
            ^headline_opts()
          ),
        ts: t.inserted_at,
        rank:
          fragment(
            "ts_rank(to_tsvector('simple', coalesce(?, '')), websearch_to_tsquery('simple', ?))",
            field(t, ^field),
            ^q
          )
      },
      order_by: [
        desc:
          fragment(
            "ts_rank(to_tsvector('simple', coalesce(?, '')), websearch_to_tsquery('simple', ?))",
            field(t, ^field),
            ^q
          ),
        desc: t.inserted_at
      ],
      limit: ^take
    )
    |> filter_conversation(opts)
    |> filter_since(:t, opts)
    |> Repo.all()
  end

  # ── filters ─────────────────────────────────────────────────────────────

  # `agent_id` / `conversation_id` are on the conversation row; on the turn
  # queries that is the joined `:conv` binding, on the title query the root.
  defp filter_conversation(query, opts) do
    query
    |> maybe_where(:agent_id, opts[:agent_id])
    |> maybe_where(:conversation_id, opts[:conversation_id])
  end

  defp maybe_where(query, _field, nil), do: query
  defp maybe_where(query, _field, ""), do: query

  defp maybe_where(query, :agent_id, id) do
    if has_named_binding?(query, :conv),
      do: where(query, [conv: c], c.agent_id == ^id),
      else: where(query, [c], c.agent_id == ^id)
  end

  defp maybe_where(query, :conversation_id, id) do
    if has_named_binding?(query, :conv),
      do: where(query, [conv: c], c.id == ^id),
      else: where(query, [c], c.id == ^id)
  end

  defp filter_since(query, _binding, opts) do
    case opts[:since] do
      %DateTime{} = since ->
        where(query, [row], row.inserted_at >= ^since)

      _ ->
        query
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  # Plain text, one fragment, no markup: a client renders the snippet as
  # text; anything it wants highlighted it finds with the query it sent.
  defp headline_opts,
    do:
      ~s(StartSel="", StopSel="", MaxFragments=1, MaxWords=#{@snippet_words}, ) <>
        ~s(MinWords=#{div(@snippet_words, 2)}, FragmentDelimiter=" … ")

  # `-foo` alone is `!foo` to Postgres, which matches every row that lacks
  # it — the whole tenant. A search box means "find", so a query with only
  # exclusions finds nothing.
  defp positive_term?(q) do
    q
    |> String.split()
    |> Enum.any?(&(not String.starts_with?(&1, "-") and String.downcase(&1) != "or"))
  end

  defp clamp(n, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_, lo, _hi), do: lo
end
