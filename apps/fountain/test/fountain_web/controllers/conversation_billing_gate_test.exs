defmodule FountainWeb.ConversationBillingGateTest do
  use FountainWeb.ConnCase, async: true

  alias Fountain.Repo

  describe "POST /api/conversations billing gate" do
    test "returns 402 when subscription is canceled" do
      user = insert_verified_user()
      user = Ecto.Changeset.change(user, subscription_status: "canceled") |> Repo.update!()
      {_key_record, raw_key} = insert_api_key(user, "billing-gate-test")
      agent = insert_agent()

      conn =
        build_conn()
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{agent_id: agent.id})

      assert conn.status == 402
      assert Jason.decode!(conn.resp_body)["error"] == "subscription_required"
    end

    test "returns 402 when subscription is past_due" do
      user = insert_verified_user()
      user = Ecto.Changeset.change(user, subscription_status: "past_due") |> Repo.update!()
      {_key_record, raw_key} = insert_api_key(user, "billing-gate-past-due")
      agent = insert_agent()

      conn =
        build_conn()
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{agent_id: agent.id})

      assert conn.status == 402
    end
  end
end
