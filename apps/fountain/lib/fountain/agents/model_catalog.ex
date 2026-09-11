defmodule Fountain.Agents.ModelCatalog do
  @moduledoc """
  The curated model suggestions the agent form offers and `/api/catalog`
  serves, per runtime.

  Product data, not a rule: these are **suggestions, not an allowlist**.
  `Fountain.Agents.Agent` accepts any model id under a known provider, and
  the parsing it validates with (`split/1`, `provider_for_runtime/1`,
  `known_provider?/1`) is the library's, `Managoat.Runtimes.Model`. What this
  module adds is the list, and the reason it is only a list is below.
  """

  alias Managoat.Runtimes.Model

  # Curated, deliberately short suggestion list — newest first per provider.
  #
  # The *model id* half is never gated on this list: a model released after the
  # last deploy has to be usable the day it ships, so an unrecognised id is
  # accepted and passed to the CLI verbatim (the form says so; see #554). The
  # *provider* half is gated, because the set is not open — Fountain can only
  # export credentials for these three (`InferenceCredentials.Credential` has a
  # column per provider, and `OpenCode.default_env/2` maps exactly these three
  # prefixes). A typo like `anthopic/...` used to reach the sprite with no
  # inference credentials at all and fail as an auth error in the conversation
  # log; `Agent.changeset/2` now rejects it at write time.
  #
  # #970 asked whether the picker should instead verify a model against the
  # provider. It should not, and the reason is worth keeping:
  #
  #   * The listings lie. Google's `GET /v1beta/models` still returns
  #     `gemini-2.5-pro` with `generateContent` among its supported methods,
  #     months after the API stopped serving it to new keys. So does gemini's
  #     own ACP adapter, which accepted `session/set_model` for that id and
  #     failed only when the turn called it.
  #   * The only authoritative check is a real inference call, per tenant key,
  #     billed, at form time — for an answer that is true for one key at one
  #     moment and that a retirement can invalidate the next day.
  #   * A verified picker would still not have caught #970. The agent was saved
  #     while the model worked.
  #
  # The catalog therefore stays advice, and the honest guarantee is made at the
  # other end: when the provider does refuse a model, the peer names that as
  # the kind of failure and the tenant reads the provider's own sentence, which
  # names the replacement. See `Managoat.ACP.Peer`'s
  # `model_unavailable?/1` and its handler in `ConversationServer`.
  #
  # Every id below was checked with a real inference call on 2026-08-22, per
  # provider, on this instance's own keys, and re-checked against the pinned
  # ACP adapters on 2026-09-06.
  #
  # ## A suggestion has to clear two gates, not one
  #
  # The provider serving a model is necessary and not sufficient. The pinned
  # adapter (`Managoat.Runtimes.ACP`) has its own accepted set, and it is the
  # one a turn meets first: `session/set_model` is refused before a prompt is
  # ever written. Between 2026-08-16 and 2026-09-06 this catalog suggested
  # three anthropic ids the adapter refused on every turn — 289 refusals for
  # `claude-sonnet-4-6` alone — and nobody noticed, because a refusal fell
  # back to the runtime's default and answered anyway. #1640 made a refusal
  # fatal, which is correct and which turned 47 agents' worth of invisible
  # fallback into dead conversations overnight.
  #
  # So: check the adapter, not just the provider, and check it again whenever
  # an adapter pin moves. The cheap standing check is the refusal rate per
  # requested model in `log_events` (`stage='model', state='failed'`) against
  # turns for the same model — a suggestion refused on most of its turns is
  # not a suggestion, it is an outage waiting for someone to enforce it.
  @catalog %{
    # `claude-fable-5-1` was added on 2026-09-06 (#1659) from Anthropic's
    # published model id, with no local inference check and no adapter check,
    # and removed on 2026-09-07 (#1669) once it had run turns: the pinned
    # `claude-agent-acp` refuses it at `session/set_model` with "Invalid value
    # for config option model", exactly like the three below. It was added in
    # the same window this file's two-gates note was written and survived the
    # clean-up that removed the others, because a published provider id looks
    # like the check has already been done. It is gate one; the adapter is the
    # gate that decides a turn.
    #
    # `claude-opus-4-8`, `claude-opus-4-7` and `claude-sonnet-4-6` were removed
    # on 2026-09-06. All three answer a real inference call — the 2026-08-22
    # check was not wrong — but the pinned `claude-agent-acp` adapter refuses
    # them at `session/set_model` with "Invalid value for config option model",
    # so a turn never reaches the provider at all. See the two-gates note
    # above `@catalog`.
    "anthropic" => ~w(
      claude-opus-5
      claude-sonnet-5
      claude-haiku-4-5
    ),
    # `gpt-5-codex` was retired and removed on 2026-08-22 — the same defect as
    # the google entries below, and a worse one, because it was the suggestion
    # *and* the form placeholder for the codex runtime, so it was what a new
    # codex user was told to type. `/v1/responses` answers 404 "Model not
    # found gpt-5-codex" for it and 200 for `gpt-5.3-codex`.
    #
    # A trap for the next person to check this: codex-line models are not
    # served on `/v1/responses` once they are old, so a 404 there is a real
    # retirement — but `GET /v1/models` still lists every one of them
    # (`gpt-5.1-codex`, `gpt-5.2-codex`, ...). The listing lies here exactly as
    # it does for google. `gpt-5` still answers 200 and was replaced only for
    # being five releases behind.
    #
    # `gpt-5.3-codex` was removed on 2026-09-06 and `gpt-6-astra` added: the
    # codex-acp bump to 1.10.0 (#1640) moved the adapter's accepted set, which
    # is a *third* way a suggestion goes stale, independent of both the
    # provider and `/v1/responses`.
    "openai" => ~w(gpt-6-astra gpt-5.5),
    # Both 2.5 entries were removed on 2026-08-22: Google retired
    # `gemini-2.5-pro` *and* `gemini-2.5-flash` for new API keys, so every
    # model Fountain suggested for google answered
    # "no longer available to new users" on a key issued after the cutoff.
    # Verified against generativelanguage.googleapis.com, not inferred from a
    # release note. `gemini-3.1-pro-preview` is the replacement Google's own
    # error names; the flash tier is listed newest-first beside it.
    "google" => ~w(
      gemini-3.1-pro-preview
      gemini-3.7-flash
      gemini-3.6-flash
      gemini-3.5-flash
    )
  }

  @doc "Providers Fountain can export inference credentials for, in display order."
  @spec providers() :: [String.t()]
  defdelegate providers, to: Model

  @doc """
  Suggested canonical `provider/model_id` strings for a runtime — the
  runtime's own provider for claude / codex / gemini, every provider for
  opencode (and for an unrecognised runtime, which the changeset rejects
  separately).

  These are suggestions, not an allowlist. `Agent.changeset/2` accepts any
  model id under a known provider.
  """
  @spec suggestions(String.t() | nil) :: [String.t()]
  def suggestions("fountain-fixture"), do: ["fixture/deterministic-v1"]

  # The acp runtime resolves no inference credential and reads no model, so
  # suggesting one would be advice to fill in a field that does nothing.
  def suggestions("acp"), do: []

  def suggestions(runtime) do
    case Model.provider_for_runtime(runtime) do
      nil -> Enum.flat_map(Model.providers(), &suggestions_for_provider/1)
      provider -> suggestions_for_provider(provider)
    end
  end

  @doc "Whether a canonical model string is one of the curated suggestions."
  @spec known?(String.t() | nil) :: boolean()
  def known?(model) do
    case Model.split(model) do
      {nil, nil} -> false
      {provider, id} -> id in Map.get(@catalog, provider, [])
    end
  end

  defp suggestions_for_provider(provider) do
    @catalog |> Map.fetch!(provider) |> Enum.map(&"#{provider}/#{&1}")
  end
end
