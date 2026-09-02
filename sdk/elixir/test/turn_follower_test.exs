defmodule Fountain.TurnFollowerTest do
  use ExUnit.Case, async: true
  alias Fountain.TurnFollower

  test "filters other turns and surfaces answerable permission requests" do
    follower = TurnFollower.new(2)

    {follower, []} =
      TurnFollower.apply(follower, %{
        "kind" => "stage",
        "stage" => "turn",
        "state" => "started",
        "data" => %{"turn_number" => 1}
      })

    {follower, [%{type: :turn_start}]} =
      TurnFollower.apply(follower, %{
        "kind" => "stage",
        "stage" => "turn",
        "state" => "started",
        "data" => %{"turn_number" => 2, "turn_id" => "t2"}
      })

    block = %{
      "kind" => "permission_request",
      "request_id" => "r1",
      "name" => "shell",
      "options" => [%{"optionId" => "allow", "kind" => "allow_once"}]
    }

    {follower, [%{type: :block}, %{type: :permission, request: request}]} =
      TurnFollower.apply(follower, %{"kind" => "output", "turn_id" => "t2", "blocks" => [block]})

    assert request.request_id == "r1"
    assert hd(request.options).option_id == "allow"
    refute TurnFollower.finished?(follower)
  end
end
