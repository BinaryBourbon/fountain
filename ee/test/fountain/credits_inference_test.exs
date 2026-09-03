defmodule Fountain.Credits.InferenceTest do
  @moduledoc """
  Pricing a platform-inference turn (#1388): the rate card, the pricer's
  fourth pass, and what the finance panel makes of it.

  `async: false` — the rate override and the platform keys are application
  environment, and a module that writes it races every module that reads it
  (#1214).
  """

  use Fountain.DataCase, async: false

  alias Fountain.Billing
  alias Fountain.Billing.Finance
  alias Fountain.Credits
  alias Fountain.Credits.InferenceRates
  alias Fountain.Workers.CreditPricer

  @since ~U[2026-08-01 00:00:00Z]
  @now ~U[2026-08-03 12:00:00Z]

  setup do
    original = Application.get_env(:fountain, :inference_rates)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fountain, :inference_rates)
        value -> Application.put_env(:fountain, :inference_rates, value)
      end
    end)

    :ok
  end

  defp platform_turn(conv, usage, opts \\ []) do
    started = Keyword.get(opts, :started_at, ~U[2026-08-02 10:00:00Z])

    insert_turn(conv, %{
      status: "completed",
      started_at: started,
      ended_at: DateTime.add(started, Keyword.get(opts, :seconds, 60), :second),
      usage: usage
    })
  end

  defp conv_for(user, provider \\ "sprites") do
    sandbox = insert_sandbox(user_id: user.id, provider: provider, status: "ready")
    insert_conversation(user_id: user.id, sandbox: sandbox)
  end

  describe "InferenceRates" do
    test "a million input tokens on opus 5 is $5 and a million output is $25" do
      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => 1_000_000,
               "output" => 0
             }) == 500

      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => 0,
               "output" => 1_000_000
             }) == 2_500
    end

    test "cached tokens are priced at their own published rate, not as input" do
      # Opus 5: cache reads are 0.1x base input, 5-minute writes 1.25x.
      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => 0,
               "output" => 0,
               "cache_read" => 1_000_000,
               "cache_write" => 1_000_000
             }) == 50 + 625
    end

    test "a fraction of a cent per million tokens survives the unit" do
      # OpenAI's cached input for gpt-5.3-codex is $0.175/MTok.
      assert InferenceRates.cost_cents(%{
               "model" => "openai/gpt-5.3-codex",
               "cache_read" => 4_000_000
             }) == 70
    end

    test "an unlisted model falls back to the provider's flagship rate" do
      assert InferenceRates.rate_for("anthropic/claude-opus-9") ==
               InferenceRates.rate_for("anthropic/claude-opus-5")
    end

    test "a provider Fountain holds no key for prices nothing" do
      assert InferenceRates.cost_cents(%{"model" => "ollama/llama3", "input" => 9_999_999}) == 0
      assert InferenceRates.cost_cents(%{"input" => 9_999_999}) == 0
      assert InferenceRates.cost_cents(nil) == 0
    end

    test "a token count that is not a non-negative integer counts as nothing" do
      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => "lots",
               "output" => -5
             }) == 0
    end

    test "a config override replaces one entry and leaves the rest compiled" do
      Application.put_env(:fountain, :inference_rates, %{
        "anthropic/claude-opus-5" => %{
          input: 1_000_000,
          output: 0,
          cache_read: 0,
          cache_write: 0
        }
      })

      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => 1_000_000
             }) == 1_000

      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-sonnet-5",
               "input" => 1_000_000
             }) == 200
    end

    test "rounding is to the nearest cent, once" do
      # At $5/MTok a cent is 2,000 tokens, so 400 of them is 0.2 cents.
      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => 400
             }) == 0

      # 1,200 is 0.6 cents, and rounds the other way.
      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => 1_200
             }) == 1

      # Rounded once from the total, not per token kind: two 0.6-cent halves
      # are 1.2 cents and one row, not two rows of one cent.
      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => 1_200,
               "cache_write" => 960
             }) == 1
    end
  end

  describe "the pricer's inference pass" do
    test "a platform turn burns its tokens, once, beside the turn-time burn" do
      user = insert_empty_user()
      conv = conv_for(user)

      turn =
        platform_turn(
          conv,
          %{
            "inference" => "platform",
            "model" => "anthropic/claude-sonnet-5",
            "input" => 1_000_000,
            "output" => 500_000
          },
          seconds: 3_600
        )

      assert %{turns: 1, inference: 1} = CreditPricer.run(since: @since, now: @now)

      # $2 of input plus $5 of output is 700 cents of inference, and the hour
      # of turn time is 25 more. Two rows, two reasons: Fountain's margin is
      # the second one.
      assert Credits.balance(user.id) == -725

      [entry] = Credits.list_entries(user.id) |> Enum.filter(&(&1.reason == "burn_inference"))
      assert entry.resource_type == "turn"
      assert entry.resource_id == turn.id
      assert entry.idempotency_key == "burn_inference:#{turn.id}"
      assert entry.metadata["model"] == "anthropic/claude-sonnet-5"
      assert entry.metadata["input"] == 1_000_000
      assert entry.metadata["conversation_id"] == conv.id

      assert %{inference: 0} = CreditPricer.run(since: @since, now: @now)
      assert Credits.balance(user.id) == -725
    end

    test "a turn on the tenant's own key burns nothing for inference" do
      user = insert_empty_user()
      conv = conv_for(user)

      platform_turn(conv, %{
        "inference" => "own",
        "input" => 1_000_000,
        "output" => 1_000_000
      })

      assert %{inference: 0} = CreditPricer.run(since: @since, now: @now)
      assert Credits.list_entries(user.id) == []
    end

    test "an unmarked turn — the shape every turn had before #1388 — burns nothing" do
      user = insert_empty_user()
      conv = conv_for(user)

      platform_turn(conv, %{"input" => 1_000_000, "output" => 1_000_000})

      assert %{inference: 0} = CreditPricer.run(since: @since, now: @now)
    end

    test "a runner turn costs no sandbox time and still burns its platform tokens" do
      user = insert_empty_user()
      conv = conv_for(user, "runner")

      platform_turn(
        conv,
        %{
          "inference" => "platform",
          "model" => "anthropic/claude-opus-5",
          "input" => 1_000_000
        },
        seconds: 3_600
      )

      # The turn pass skips it (ADR 0022: Fountain pays for no runner hour);
      # the inference pass does not, because the tokens were still on
      # Fountain's key.
      assert %{turns: 0, inference: 1} = CreditPricer.run(since: @since, now: @now)
      assert Credits.balance(user.id) == -500
    end

    test "a turn that rounds to nothing writes no row" do
      user = insert_empty_user()
      conv = conv_for(user)

      platform_turn(conv, %{
        "inference" => "platform",
        "model" => "anthropic/claude-opus-5",
        "input" => 100
      })

      assert %{inference: 0} = CreditPricer.run(since: @since, now: @now)
      assert Credits.list_entries(user.id) == []
    end

    test "an open turn is not priced until it closes" do
      user = insert_empty_user()
      conv = conv_for(user)

      insert_turn(conv, %{
        status: "running",
        started_at: ~U[2026-08-02 10:00:00Z],
        usage: %{
          "inference" => "platform",
          "model" => "anthropic/claude-opus-5",
          "input" => 10_000_000
        }
      })

      assert %{inference: 0} = CreditPricer.run(since: @since, now: @now)
    end
  end

  describe "the ceiling and the finance panel" do
    test "spend today is the day's burn_inference rows, across every tenant" do
      one = insert_empty_user()
      two = insert_empty_user()

      {:ok, _} =
        Credits.debit(one.id, 120, "burn_inference",
          idempotency_key: "burn_inference:a",
          actor: "system:test"
        )

      {:ok, _} =
        Credits.debit(two.id, 80, "burn_inference",
          idempotency_key: "burn_inference:b",
          actor: "system:test"
        )

      # A turn-time burn is not inference spend.
      {:ok, _} =
        Credits.debit(one.id, 500, "burn_turn",
          idempotency_key: "burn_turn:x",
          actor: "system:test"
        )

      assert Billing.platform_inference_spend_today() == 200
    end

    test "the finance panel counts inference as both earned and paid, netting to zero" do
      user = insert_empty_user()
      now = DateTime.utc_now()
      {start, _} = Billing.current_month_range()

      {:ok, _} =
        Credits.debit(user.id, 300, "burn_inference",
          idempotency_key: "burn_inference:finance",
          actor: "system:test"
        )

      summary = Finance.summary(period: {start, DateTime.add(now, 1, :day)}, now: now)
      row = Enum.find(summary.tenants, &(&1.user_id == user.id))

      assert row.inference_cost_cents == 300
      assert row.revenue_cents == 300
      assert row.credit_burned_cents == 300
      assert summary.cost.inference_cents == 300
      # Pass-through: the tenant paid exactly what the tokens cost.
      assert row.margin_cents == 0
    end
  end
end
