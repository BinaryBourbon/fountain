defmodule Fountain.Conversations.ACPModelContractTest do
  @moduledoc """
  What Fountain needs `managoat_acp` to do when a runtime confirms a model.

  The library has its own suite and this does not duplicate it. What it pins
  is the half Fountain depends on and cannot see: `apps/fountain/mix.exs`
  allows `~> 0.4.2`, so later 0.4.x releases resolve without a change here,
  and this behaviour is what decides whether a turn runs at all. Since #1640 a
  `session/set_model` disagreement fails the turn before a prompt is written,
  so the blast radius of getting it wrong is every turn on the affected
  runtime — 120 of 143 agents were claude when this last happened.

  It has already gone wrong twice in production, on consecutive days, and both
  times CI here was green:

  * 2026-09-06, `managoat_acp` 0.2.0 — strict string equality. Claude accepts
    `claude-opus-5` and confirms `opus`, so every claude turn failed. Codex
    echoes the id verbatim, kept working, and disguised a comparison bug as a
    model-catalog problem. Fixed in 0.2.2.
  * 2026-09-06, `managoat_acp` 0.2.2 — the containment fix dropped separators,
    which fused a variant qualifier onto the family name: claude confirms
    `opus[1m]` for the 1M-context build, `opus1m` against `claudeopus5` agreed
    with neither direction, and the turn failed again. Fixed in 0.2.3.

  Both directions matter, and a test that only pinned agreement would have
  passed against 0.2.0's strict equality for `gpt-6-astra`. So the cases below
  are the two that a comparison has to get right at once: a canonical or
  qualified designation of the model asked for is the **same** model, and a
  different family is a **substitution** that still fails.

  The transport is the writer function the peer takes, so this runs a real
  `Managoat.ACP.Peer` with no sandbox, no port and nothing stubbed.
  """

  use ExUnit.Case, async: true

  alias Managoat.ACP.Peer

  setup do
    test = self()

    writer = fn data ->
      send(test, {:wrote, IO.iodata_to_binary(data)})
      :ok
    end

    {:ok, ref: make_ref(), writer: writer}
  end

  defp start_peer(ctx, model) do
    {:ok, pid} =
      Peer.start(
        owner: self(),
        writer: ctx.writer,
        ref: ctx.ref,
        prompt: "do the thing",
        mode: :run,
        session_id: nil,
        cwd: "/work",
        images: [],
        mcp_servers: [],
        model: model
      )

    pid
  end

  defp next_write do
    assert_receive {:wrote, line}, 1_000
    Jason.decode!(line)
  end

  defp send_response(pid, id, result) do
    Peer.stdout(pid, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}) <> "\n")
  end

  # Walks the handshake to the point where the runtime answers `set_model`,
  # then answers it with whatever the runtime is pretending to confirm.
  defp confirm_model(ctx, requested, confirmed) do
    pid = start_peer(ctx, requested)

    %{"id" => init_id} = next_write()

    send_response(pid, init_id, %{
      "agentCapabilities" => %{"loadSession" => true, "sessionCapabilities" => %{"resume" => %{}}}
    })

    %{"id" => new_id} = next_write()
    send_response(pid, new_id, %{"sessionId" => "s", "configOptions" => [%{"id" => "model"}]})

    %{"id" => set_id} = next_write()

    send_response(pid, set_id, %{
      "configOptions" => [%{"id" => "model", "currentValue" => confirmed}]
    })

    pid
  end

  describe "a runtime's own designation of the model we asked for" do
    # `opus[1m]` is the case 0.2.2 shipped and still failed on. It is literal
    # text, not an ANSI escape, and it is a variant of the requested model
    # rather than a different one.
    for {requested, confirmed} <- [
          {"claude-opus-5", "opus"},
          {"claude-sonnet-5", "sonnet"},
          {"claude-opus-5", "opus[1m]"},
          {"gpt-6-astra", "gpt-6-astra"}
        ] do
      test "#{requested} confirmed as #{confirmed} sends the prompt", ctx do
        confirm_model(ctx, unquote(requested), unquote(confirmed))

        assert_receive {:acp, _, {:model_selected, unquote(requested), unquote(confirmed), _}}
        assert %{"method" => "session/prompt"} = next_write()
      end
    end
  end

  describe "a runtime quietly answering as a different model" do
    # The reason the comparison exists. If this stops failing, the enforcement
    # #1640 added is gone and a turn can run on a model nobody asked for.
    for confirmed <- ["claude-haiku-4-5", "haiku[1m]"] do
      test "claude-opus-5 confirmed as #{confirmed} fails the turn", ctx do
        confirm_model(ctx, "claude-opus-5", unquote(confirmed))

        assert_receive {:acp, _, {:failed, {:model_selection_failed, "claude-opus-5", detail}}}
        assert detail =~ unquote(confirmed)

        # No prompt is written: the turn dies before inference is paid for.
        refute_receive {:wrote, _}, 50
      end
    end
  end
end
