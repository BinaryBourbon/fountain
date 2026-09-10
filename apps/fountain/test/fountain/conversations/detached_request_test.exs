defmodule Fountain.Conversations.DetachedRequestTest do
  @moduledoc """
  A permission request that outlived its turn (#1635), from the row it lives
  on to the turn its answer opens.

  The `ConversationServer` half — the `waiting` stop reason, the deadline the
  ask decides and the `session/prompt` the resume turn writes — is in
  `conversation_server_acp_test.exs`, where a real peer is driven. What is
  here is what happens with no peer at all, which is the state a detached
  request spends its life in.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Conversations.DetachedRequest

  @options [
    %{"optionId" => "allow", "kind" => "allow_once", "name" => "Apply"},
    %{"optionId" => "deny", "kind" => "reject_once", "name" => "Stop"}
  ]

  describe "the wire shape of the resume prompt" do
    test "is one line of JSON under the key a _meta field would use" do
      request = %{"request_id" => "7.abc", "tool" => "Bash"}
      prompt = DetachedRequest.resume_prompt(request, "answered", "allow")

      refute String.contains?(prompt, "\n")

      assert %{"fountain/permission_answer" => answer} = Jason.decode!(prompt)
      assert answer["request_id"] == "7.abc"
      assert answer["tool"] == "Bash"
      assert answer["outcome"] == "answered"
      assert answer["option_id"] == "allow"
      assert {:ok, _, _} = DateTime.from_iso8601(answer["answered_at"])
    end

    test "an expiry carries the outcome and the option the agent itself offered" do
      request = %{"request_id" => "7.abc", "tool" => "Bash", "options" => @options}
      option_id = DetachedRequest.deny_option_id(request)
      assert option_id == "deny"

      assert %{"fountain/permission_answer" => %{"outcome" => "timeout", "option_id" => "deny"}} =
               request
               |> DetachedRequest.resume_prompt("timeout", option_id)
               |> Jason.decode!()
    end

    test "an agent that offered no rejection gets a null option, never an invented one" do
      request = %{
        "request_id" => "7.abc",
        "options" => [%{"optionId" => "yes", "kind" => "allow_once"}]
      }

      assert DetachedRequest.deny_option_id(request) == nil
    end
  end

  describe "the deadline" do
    test "the shorter of the request and the policy wins, either way round" do
      # The request is written inside the sandbox and the policy is the
      # tenant's, so an agent may bound its own wait and may not extend one.
      long = %{"_meta" => %{"fountain" => %{"timeout" => 172_800}}}
      short = %{"_meta" => %{"fountain" => %{"timeout" => 60}}}

      assert DetachedRequest.timeout_ms(long, 600) == 600_000
      assert DetachedRequest.timeout_ms(short, 600) == 60_000
    end

    test "the request alone is honoured, past the policy's absence" do
      params = %{"_meta" => %{"fountain" => %{"timeout" => 172_800}}}
      assert DetachedRequest.timeout_ms(params, nil) == 172_800_000
    end

    test "the policy is used when the request names none" do
      assert DetachedRequest.timeout_ms(%{}, 600) == 600_000
      assert DetachedRequest.timeout_ms(nil, 600) == 600_000
    end

    test "with neither, the global ask timeout stands" do
      assert DetachedRequest.timeout_ms(nil, nil) ==
               Fountain.Conversations.Lifecycle.ask_timeout_ms()
    end

    test "a timeout that is not a positive number of seconds falls through" do
      for value <- [0, -5, "soon", "60s", nil] do
        params = %{"_meta" => %{"fountain" => %{"timeout" => value}}}
        assert DetachedRequest.timeout_ms(params, 600) == 600_000
      end
    end

    test "a deadline longer than the idle bound is accepted, which is the point" do
      # The in-turn ceiling has to sit under the idle bound because the turn
      # holding it defers idle reclaim. A detached request holds nothing open,
      # so nothing here clamps it.
      params = %{"_meta" => %{"fountain" => %{"timeout" => 2 * 24 * 3600}}}
      idle_ms = Fountain.Conversations.Lifecycle.idle_timeout_seconds() * 1000

      assert DetachedRequest.timeout_ms(params, nil) > idle_ms
    end
  end
end
