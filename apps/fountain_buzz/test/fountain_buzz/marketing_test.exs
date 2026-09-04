defmodule FountainBuzz.MarketingTest do
  @moduledoc """
  What core-owned marketing says when the extension IS installed (#1525).

  `/buzz-launch` and the Nostr card on `/integrations` are core's templates,
  and they declare `requires_extension: :buzz`. The core suite asserts the
  other half of that: from apps/fountain nothing renders and the page is a
  404. This file is the same pages on a bundled distribution, and it lives
  here because this is the suite that has the extension on its code path.

  The content assertions moved here wholesale from
  apps/fountain/test/fountain_web/controllers/marketing_controller_test.exs.
  """
  use FountainWeb.ConnCase, async: true

  test "the extension really is installed here" do
    # A diagnostic, not a guard. Every other test in this file fails if the
    # extension stops loading in this suite — verified by making
    # `available?/1` return false, which fails all seven. What this one buys
    # is the reason: one named failure instead of six about missing copy.
    assert Fountain.Marketing.available?(:buzz)
  end

  describe "GET /integrations" do
    test "carries the Nostr card the core distribution does not", %{conn: conn} do
      body = conn |> get(~p"/integrations") |> html_response(200)

      assert body =~ "Put the agent on a Nostr relay."
      assert body =~ "Nostr"
      assert body =~ "POST /api/buzz/agents"
      assert FountainWeb.MarketingHTML.outbound_protocol().id == "nostr"
    end

    test "and the MCP card lists the buzz server", %{conn: conn} do
      body = conn |> get(~p"/integrations") |> html_response(200)
      assert body =~ "fountain-buzz"

      names =
        FountainWeb.MarketingHTML.protocols()
        |> Enum.flat_map(& &1.works_with)
        |> Enum.map(& &1.name)

      assert "fountain-buzz" in names
    end

    test "every link into the manual resolves", %{conn: conn} do
      body = conn |> get(~p"/integrations") |> html_response(200)

      slugs =
        ~r/href="\/docs\/([^"#]+)/
        |> Regex.scan(body)
        |> Enum.map(fn [_, slug] -> slug end)
        |> Enum.uniq()

      assert "integrations/buzz" in slugs,
             "the Nostr card should link the extension's manual page again (#1525)"

      for slug <- slugs do
        assert match?({:ok, _}, Fountain.Manual.get(slug)), "/docs/#{slug} is not a page"
      end
    end
  end

  describe "GET /buzz-launch" do
    test "argues the agent should outlive the laptop, honestly", %{conn: conn} do
      body = conn |> get(~p"/buzz-launch") |> html_response(200)

      assert body =~ "Close your laptop. Your Buzz agent keeps answering."
      assert body =~ "hosted agents on Nostr"
      assert body =~ "Host your Buzz agent free"
      # The button came back in #1525: the ROUTE is gated on the extension, so
      # every reader of this page is on a distribution that serves the manual
      # page it links.
      assert body =~ "Read the integration manual"

      assert body =~ "Take your laptop out of the loop."
      assert body =~ "Closing the laptop takes the agent offline"
      assert body =~ "restarts it after a node loss"

      assert body =~ "From mention to signed reply."

      for step <- FountainWeb.MarketingHTML.buzz_turn_steps() do
        assert body =~ step.title, "missing turn step #{step.n}"
      end

      assert length(Regex.scan(~r/data-role="buzz-turn-step"/, body)) == 4
      assert body =~ "The agent must make an explicit tool call to publish."

      assert body =~ "The signing key never enters the sandbox."
      assert body =~ "The name collides with HashiCorp's"
      assert body =~ "buzz.published"
      assert body =~ "Recording is not gating"

      assert body =~ "Give the identity a repository and the tools to use it."
      assert body =~ "Claude Code, Codex, Gemini CLI or OpenCode"

      assert body =~ "Deploy from Buzz Desktop or the API."
      assert body =~ "buzz-backend-fountain"
      assert body =~ "$FOUNTAIN_BASE_URL/api/buzz/agents"
      assert body =~ "&quot;private_key_nsec&quot;"
      assert body =~ "stores the nsec from this request and never returns it"
      assert body =~ "updates the existing identity instead of creating a duplicate"

      assert body =~ "Control it from the Buzz channel."

      for owner_command <- FountainWeb.MarketingHTML.buzz_owner_commands() do
        assert body =~ owner_command.command, "missing owner command #{owner_command.command}"
      end

      assert body =~ "fountain buzz agents set-access"

      assert body =~ "What the integration does, and what it does not."
      assert body =~ "The harness does not publish the agent's normal response."
      assert body =~ "buzz_send_message"
      assert body =~ "buzz_react"
      assert body =~ "Publishing is audited, not approved."
      assert body =~ "Direct messages remain owner-only."
      assert body =~ "Runtime permission prompts are automatic."
      assert body =~ "Access does not make the agent discoverable."
    end

    test "carries its own card and stays out of permanent navigation", %{conn: conn} do
      body = conn |> get(~p"/buzz-launch") |> html_response(200)

      assert body =~ ~s(<meta property="og:title" content="Hosted Buzz agents · Fountain")
      assert body =~ ~s(<meta property="og:url" content="http://localhost:4000/buzz-launch")
      assert body =~ ~s(<meta name="description" content="Keep your Buzz agent on the relay)

      refute conn |> get(~p"/") |> html_response(200) =~ ~s(href="/buzz-launch")
      refute conn |> get(~p"/built-with") |> html_response(200) =~ ~s(href="/buzz-launch")
    end

    # `Fountain.Manual` and not `Fountain.Docs`: it is the manual THIS
    # distribution serves. Running from here the extension is installed, so it
    # is the merged manual, and `integrations/buzz` resolves. The core suite
    # runs the same guard against the core manual on the pages it still
    # renders, so both halves of #1510's rule are checked.
    test "every link into the manual resolves", %{conn: conn} do
      body = conn |> get(~p"/buzz-launch") |> html_response(200)

      slugs =
        ~r/href="\/docs\/([^"#]+)/
        |> Regex.scan(body)
        |> Enum.map(fn [_, slug] -> slug end)
        |> Enum.uniq()

      assert "integrations/buzz" in slugs,
             "the page should link the extension's manual again (#1525)"

      for slug <- slugs do
        assert match?({:ok, _}, Fountain.Manual.get(slug)), "/docs/#{slug} is not a page"
      end
    end
  end
end
