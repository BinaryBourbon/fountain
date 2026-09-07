defmodule Fountain.RefusedModels do
  @moduledoc """
  The model ids the pinned ACP adapters refuse at `session/set_model`, with the
  date each was observed.

  A refusal happens before a prompt is written, so since #1640 it fails the
  turn outright — naming one of these is an outage, not a stale hint. Every
  entry was served happily by its provider at the time it was refused, which is
  exactly why the provider check alone did not catch it: see the two-gates note
  in `Fountain.Agents.ModelCatalog`.

  ## This is a registry, not a catalog test detail

  It lived inside `Fountain.Agents.ModelCatalogTest` until #1669, where its only
  assertion read `ModelCatalog.suggestions/1` and nothing else. That is how
  `claude-sonnet-4-6` stayed the new-agent form's prefilled default and
  `gpt-5.3-codex` its codex placeholder through the 2026-09-06 clean-up that
  removed both from the catalog: the guard covered the weakest surface.

  A suggestion has to be chosen. A **default** is what a user gets by doing
  nothing, and a **placeholder** is what they get by typing the hint. Both are
  stronger claims than a suggestion, so every surface that names a model reads
  this one map. Adding a surface means adding a test that consumes it here, not
  a second copy of the list.

  Surfaces still outside its reach are tracked on #1727: the shipped `fountain`
  skill manifest, the `/help` pages and the OpenAPI field description.

  ## Removing an entry

  Legitimate **after** an adapter pin moves and the id is confirmed accepted on
  a real turn. Not legitimate because the model answers a `curl` to the
  provider — that is gate one, and the adapter is the gate that decides a turn.

  The refusal-rate check that finds new entries (`log_events`, `stage='model'`
  and `state='failed'`, against turns for the same model) cannot *clear* an id
  that is never suggested: it accrues no turns, so its rate is zero of zero
  forever. Clear those by driving one real turn.
  """

  @refused %{
    # claude-agent-acp 0.66.0 — "Invalid value for config option model".
    # 289 refusals for claude-sonnet-4-6 alone, 2026-08-16..2026-09-06.
    "anthropic/claude-sonnet-4-6" => "2026-09-06",
    # Both observed refused on real turns, one turn each, minutes apart:
    # claude-fable-5-1 at 11:42:46 UTC and claude-fable-5 at 11:45:46 UTC, both
    # "Invalid value for config option model" (#1669). claude-fable-5-1 was
    # suggested for one day (#1659); claude-fable-5 never was, and reached a
    # turn only because one agent is pinned to it by hand.
    #
    # Both are live published Anthropic ids, so these two rows bar a current
    # model rather than a retired one. Deliberate while the adapter refuses
    # them, and the pair the "drive one real turn" clause above exists for.
    "anthropic/claude-fable-5-1" => "2026-09-06",
    "anthropic/claude-fable-5" => "2026-09-06",
    "anthropic/claude-opus-4-7" => "2026-08-27",
    "anthropic/claude-opus-4-8" => "2026-08-23",
    # codex-acp 1.10.0 — "Invalid params". Refused after the #1640 bump that
    # added gpt-6-astra; it was accepted by 1.9.x.
    "openai/gpt-5.3-codex" => "2026-09-06",
    # Google retired it for new keys; opencode's adapter refused it too.
    "google/gemini-2.5-pro" => "2026-08-20"
  }

  @doc "The refused ids, mapped to the date each was observed refused."
  @spec all() :: %{String.t() => String.t()}
  def all, do: @refused

  @doc "Just the ids."
  @spec ids() :: [String.t()]
  def ids, do: Map.keys(@refused)
end
