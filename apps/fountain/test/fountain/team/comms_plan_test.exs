defmodule Fountain.Team.CommsPlanTest do
  @moduledoc """
  The ceiling on teammate contacts (`TEAM_CONTACT_CEILING`), and that
  runs when one is provisioned or released.

  Contacts are billed per unit, so the ceiling is not an entitlement. It bounds
  how much Fountain can be made to buy in one burst while the quantity sync is
  failing, which is exactly the window in which it would be paying for numbers
  it is not charging for.
  """
  # Flips the `team_comms` flag through global app env, so not async.
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.{Plans, Team}
  alias Fountain.Team.Comms
  alias Fountain.Team.Comms.{AgentMail, AgentPhone}

  setup do
    previous = Application.get_env(:fountain, :feature_flag_overrides)
    Application.put_env(:fountain, :feature_flag_overrides, %{"team_comms" => true})

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fountain, :feature_flag_overrides)
        value -> Application.put_env(:fountain, :feature_flag_overrides, value)
      end
    end)

    stub_providers()
    :ok
  end

  @req %{"prompt_from_number" => "+15550001111"}

  defp teammate(user, name) do
    agent = insert_agent(user_id: user.id, name: name)

    insert_conversation(
      user_id: user.id,
      agent: agent,
      status: "idle",
      channel_id: Team.channel()
    )

    agent
  end

  # Unique ids per call, so a test can provision several contacts in a row.
  defp stub_providers do
    Req.Test.stub(AgentMail, fn conn ->
      n = System.unique_integer([:positive])

      case conn.method do
        "POST" -> Req.Test.json(conn, %{"inbox_id" => "inbox_#{n}", "email" => "a#{n}@mail.to"})
        "DELETE" -> Req.Test.json(conn, %{})
      end
    end)

    Req.Test.stub(AgentPhone, fn conn ->
      n = System.unique_integer([:positive])

      case {conn.method, conn.request_path} do
        {"POST", "/v1/agents"} ->
          Req.Test.json(conn, %{"id" => "agt_#{n}"})

        {"POST", "/v1/numbers"} ->
          Req.Test.json(conn, %{"id" => "num_#{n}", "phoneNumber" => "+1555000#{n}"})

        {"DELETE", _} ->
          Req.Test.json(conn, %{})
      end
    end)
  end

  defp provision(user, name) do
    agent = teammate(user, name)
    {agent, Comms.provision_contact(user.id, agent.id, @req)}
  end

  defp fill_to_ceiling(user) do
    for n <- 1..Application.get_env(:fountain, :team_contact_ceiling, 10) do
      {_agent, {:ok, _contact}} = provision(user, "mate-#{n}")
    end
  end

  describe "contact_count/1" do
    test "counts only this tenant's contacts" do
      user = insert_active_user()
      other = insert_active_user()

      {_a, {:ok, _}} = provision(user, "Ada")
      {_b, {:ok, _}} = provision(other, "Bob")

      assert Comms.contact_count(user.id) == 1
      assert Comms.contact_count(other.id) == 1
    end
  end

  describe "the contact ceiling" do
    test "a teammate under the ceiling gets a contact" do
      user = insert_active_user()
      assert {_agent, {:ok, _contact}} = provision(user, "Ada")
    end

    test "refuses at the ceiling, and says which one" do
      user = insert_active_user()
      fill_to_ceiling(user)

      limit = Application.get_env(:fountain, :team_contact_ceiling, 10)
      {_agent, result} = provision(user, "one-too-many")

      assert {:error, {:contact_limit_reached, %{count: ^limit, limit: ^limit}}} = result
    end

    test "a raised ceiling allows more" do
      previous = Application.get_env(:fountain, :team_contact_ceiling)
      on_exit(fn -> Application.put_env(:fountain, :team_contact_ceiling, previous) end)
      Application.put_env(:fountain, :team_contact_ceiling, 2)

      user = insert_active_user()
      {_a, {:ok, _}} = provision(user, "mate-1")
      {_b, {:ok, _}} = provision(user, "mate-2")
      {_c, refused} = provision(user, "mate-3")
      assert {:error, {:contact_limit_reached, _}} = refused

      Application.put_env(:fountain, :team_contact_ceiling, 3)
      assert {_agent, {:ok, _}} = provision(user, "mate-4")
    end

    # Nothing is bought before the ceiling is checked: a refused provision must
    # not leave an orphan inbox or number behind at the provider.
    test "buys nothing when it refuses" do
      user = insert_active_user()
      fill_to_ceiling(user)
      before = Comms.contact_count(user.id)

      Req.Test.stub(AgentMail, fn _conn -> flunk("no inbox should be created") end)
      Req.Test.stub(AgentPhone, fn _conn -> flunk("no number should be created") end)

      {_agent, {:error, {:contact_limit_reached, _}}} = provision(user, "refused")
      assert Comms.contact_count(user.id) == before
    end

    test "releasing one makes room again" do
      user = insert_active_user()
      fill_to_ceiling(user)
      {agent, _} = provision(user, "refused")

      first = Comms.contact_count(user.id)
      [%{agent_id: release_id} | _] = Fountain.Repo.all(Fountain.Team.Contact)
      assert :ok = Comms.release_contact(user.id, release_id)

      assert Comms.contact_count(user.id) == first - 1
      assert {:ok, _} = Comms.provision_contact(user.id, agent.id, @req)
    end
  end
end
