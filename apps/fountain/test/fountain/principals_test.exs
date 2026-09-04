defmodule Fountain.PrincipalsTest do
  @moduledoc """
  Claimable principals (ADR 0044, #1551).

  The property under test throughout is the one the feature exists for: a
  machine started before a claim is the *same* machine after it. Every
  assertion about ids surviving is that property, not incidental coverage.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Accounts
  alias Fountain.Credits
  alias Fountain.Principals
  alias Fountain.Principals.ClaimableUser

  defp application_account, do: insert_verified_user()

  defp open(app, params \\ %{}, opts \\ []) do
    params = Map.merge(%{"application_id" => "paddock"}, params)
    {:ok, result} = Principals.create_claimable(app, params, opts)
    result
  end

  describe "create_claimable/3" do
    test "opens a principal that is a real, isolated tenant" do
      app = application_account()
      %{claimable: c, api_key: raw, claim_token: token} = open(app)

      principal = Accounts.get_user(c.user_id)

      assert principal.principal
      assert is_nil(principal.email)
      assert c.status == "unclaimed"
      assert c.application_user_id == app.id
      assert principal.id != app.id

      # Both secrets come back once and are stored only as hashes.
      assert String.starts_with?(raw, "ftn_")
      assert is_binary(token)
      refute c.claim_token_hash == token
    end

    test "the principal authenticates despite never verifying an email" do
      app = application_account()
      %{claimable: c, api_key: raw} = open(app)

      assert {:ok, user, key} = Accounts.authenticate_api_key(raw)
      assert user.id == c.user_id
      assert key.scopes == ["principal"]
    end

    test "max_live_sandboxes lands on the override the quota rule already reads" do
      app = application_account()
      %{claimable: c} = open(app, %{"limits" => %{"max_live_sandboxes" => 3}})

      assert Accounts.get_user(c.user_id).sandbox_limit_override == 3
      assert Fountain.Quotas.sandbox_limit(c.user_id) == 3
    end

    test "the budget is moved from the application's balance into the principal's" do
      app = application_account()
      before = Credits.balance(app.id)

      %{claimable: c} = open(app, %{"limits" => %{"max_cost_usd" => 1}})

      assert c.grant_cents == 100
      assert Credits.balance(c.user_id) == 100
      assert Credits.balance(app.id) == before - 100
    end

    test "the same idempotency key returns one principal, with fresh credentials" do
      app = application_account()
      first = open(app, %{}, idempotency_key: "pdk_123")
      second = open(app, %{}, idempotency_key: "pdk_123")

      assert first.claimable.id == second.claimable.id
      assert first.claimable.user_id == second.claimable.user_id
      # Reissued, because the first response's secrets were never stored.
      refute first.api_key == second.api_key
      refute first.claim_token == second.claim_token
    end

    test "a replay after a claim mints nothing" do
      app = application_account()
      %{claimable: c, claim_token: token} = open(app, %{}, idempotency_key: "pdk_9")
      {:ok, _} = Principals.claim(c.id, token, insert_verified_user())

      keys_before = length(Fountain.Accounts.list_api_keys(c.user_id))

      # The application kept the key. Replaying it must not hand it back a
      # working credential for a machine somebody now owns.
      assert {:error, :already_claimed} =
               Principals.create_claimable(app, %{"application_id" => "paddock"},
                 idempotency_key: "pdk_9"
               )

      assert length(Fountain.Accounts.list_api_keys(c.user_id)) == keys_before
      assert Repo.get(ClaimableUser, c.id).claim_token_hash == nil
    end

    test "a replay after a release mints nothing" do
      app = application_account()
      %{claimable: c} = open(app, %{}, idempotency_key: "pdk_10")
      {:ok, _} = Principals.release(c)

      assert {:error, :released} =
               Principals.create_claimable(app, %{"application_id" => "paddock"},
                 idempotency_key: "pdk_10"
               )
    end

    test "a principal cannot open a principal" do
      app = application_account()
      %{claimable: c} = open(app)
      principal = Accounts.get_user(c.user_id)

      assert {:error, :ineligible} =
               Principals.create_claimable(principal, %{"application_id" => "nested"})
    end

    test "an application with no balance cannot fund a principal" do
      app = insert_empty_user()

      assert {:error, :insufficient_credits} =
               Principals.create_claimable(
                 app,
                 %{"application_id" => "paddock", "limits" => %{"max_cost_usd" => 1}}
               )
    end

    test "application_id is required" do
      assert {:error, {:invalid, _}} =
               Principals.create_claimable(application_account(), %{"application_id" => "  "})
    end

    test "expires_in is clamped to the deployment's maximum" do
      app = application_account()
      %{claimable: c} = open(app, %{"expires_in" => 99_999_999})

      max = Principals.settings().max_ttl_seconds
      assert DateTime.diff(c.expires_at, DateTime.utc_now()) <= max
    end

    # The outstanding and rate ceilings live in principals_ceiling_test.exs:
    # they hold `config :fountain, Fountain.Principals`, which is global
    # application env, and this module is async.
  end

  describe "isolation between principals" do
    test "one principal cannot read another's resources" do
      app = application_account()
      %{claimable: a} = open(app)
      %{claimable: b} = open(app)

      agent = insert_agent(user_id: a.user_id)

      assert Fountain.Agents.get_agent(agent.id, a.user_id)
      refute Fountain.Agents.get_agent(agent.id, b.user_id)
      refute Fountain.Agents.get_agent(agent.id, app.id)
    end
  end

  describe "claim/4" do
    setup do
      app = application_account()
      %{claimable: c, api_key: raw, claim_token: token} = open(app)
      {:ok, app: app, claimable: c, anon_key: raw, token: token}
    end

    test "every id survives the claim", ctx do
      agent = insert_agent(user_id: ctx.claimable.user_id)
      env = insert_env(user_id: ctx.claimable.user_id)
      claimer = insert_verified_user()

      {:ok, %{claimable: claimed}} =
        Principals.claim(ctx.claimable.id, ctx.token, claimer)

      assert claimed.status == "claimed"
      # The whole point: the principal id is unchanged, so the sprite name it
      # is baked into names the same machine.
      assert claimed.user_id == ctx.claimable.user_id
      assert Fountain.Agents.get_agent(agent.id, claimed.user_id).id == agent.id
      assert Fountain.Environments.get_environment(env.id, claimed.user_id).id == env.id
      assert Principals.owner_id(claimed.user_id) == claimer.id
    end

    test "the anonymous credential stops working; the returned one does not", ctx do
      claimer = insert_verified_user()

      {:ok, %{api_key: claimed_key}} = Principals.claim(ctx.claimable.id, ctx.token, claimer)

      assert {:error, :revoked} = Accounts.authenticate_api_key(ctx.anon_key)
      assert {:ok, user, key} = Accounts.authenticate_api_key(claimed_key)
      assert user.id == ctx.claimable.user_id
      assert key.scopes == ["principal"]
      # Not the grant's deadline: that described the anonymous session, and a
      # key expiring at it would take a live machine off its new owner.
      assert is_nil(key.expires_at)
    end

    test "the anonymous credential expires with the grant", ctx do
      {:ok, _user, key} = Accounts.authenticate_api_key(ctx.anon_key)
      assert key.expires_at == ctx.claimable.expires_at
    end

    test "an account that already owns resources can claim too", ctx do
      claimer = insert_verified_user()
      own_agent = insert_agent(user_id: claimer.id)

      {:ok, %{claimable: claimed}} = Principals.claim(ctx.claimable.id, ctx.token, claimer)

      # Nothing was merged: the claimer keeps its own tenant and gains a second.
      assert Fountain.Agents.get_agent(own_agent.id, claimer.id)
      assert Principals.list_owned(claimer.id) == [claimed.user_id]
    end

    test "a wrong token is refused and changes nothing", ctx do
      claimer = insert_verified_user()

      assert {:error, :invalid_claim_token} =
               Principals.claim(ctx.claimable.id, "not-the-token", claimer)

      assert Repo.get(ClaimableUser, ctx.claimable.id).status == "unclaimed"
      assert {:ok, _, _} = Accounts.authenticate_api_key(ctx.anon_key)
    end

    test "two competing claims produce one success and one conflict", ctx do
      first = insert_verified_user()
      second = insert_verified_user()

      assert {:ok, _} = Principals.claim(ctx.claimable.id, ctx.token, first)
      assert {:error, :already_claimed} = Principals.claim(ctx.claimable.id, ctx.token, second)
      assert Principals.owner_id(ctx.claimable.user_id) == first.id
    end

    test "replaying a claim with the same key and account reissues a credential", ctx do
      claimer = insert_verified_user()
      opts = [idempotency_key: "claim_1"]

      {:ok, first} = Principals.claim(ctx.claimable.id, ctx.token, claimer, opts)
      {:ok, second} = Principals.claim(ctx.claimable.id, ctx.token, claimer, opts)

      assert first.claimable.id == second.claimable.id
      refute first.api_key == second.api_key

      # A different key from the same account is not a replay.
      assert {:error, :already_claimed} =
               Principals.claim(ctx.claimable.id, ctx.token, claimer, idempotency_key: "other")
    end

    test "an account that cannot fund future work is refused without mutating", ctx do
      broke = insert_empty_user()

      assert {:error, :ineligible} = Principals.claim(ctx.claimable.id, ctx.token, broke)

      assert Repo.get(ClaimableUser, ctx.claimable.id).status == "unclaimed"
      assert is_nil(Principals.owner_id(ctx.claimable.user_id))
      assert {:ok, _, _} = Accounts.authenticate_api_key(ctx.anon_key)
    end

    test "an expired grant cannot be claimed", ctx do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      ctx.claimable |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()

      assert {:error, :expired} =
               Principals.claim(ctx.claimable.id, ctx.token, insert_verified_user())
    end

    test "a principal cannot claim another principal", ctx do
      %{claimable: other} = open(ctx.app)
      other_principal = Accounts.get_user(other.user_id)

      assert {:error, :ineligible} =
               Principals.claim(ctx.claimable.id, ctx.token, other_principal)
    end
  end

  describe "billing_subject_id/1" do
    test "an ordinary account is its own subject" do
      user = insert_verified_user()
      assert Principals.billing_subject_id(user) == user.id
      assert Principals.billing_subject_id(user.id) == user.id
    end

    test "an unclaimed principal spends its own introductory grant" do
      %{claimable: c} = open(application_account())
      assert Principals.billing_subject_id(c.user_id) == c.user_id
    end

    test "a claimed principal spends its owner's balance" do
      app = application_account()
      %{claimable: c, claim_token: token} = open(app)
      claimer = insert_verified_user()

      {:ok, _} = Principals.claim(c.id, token, claimer)

      assert Principals.billing_subject_id(c.user_id) == claimer.id
    end

    test "the credit gate follows the subject, not the principal" do
      app = application_account()
      %{claimable: c, claim_token: token} = open(app, %{"limits" => %{"max_cost_usd" => 1}})

      # Spend the introductory grant down to nothing.
      Credits.debit(c.user_id, 100, "burn_turn", idempotency_key: "drain:#{c.user_id}")
      assert {:error, :insufficient_credits} = Fountain.Billing.check_spend(c.user_id)

      claimer = insert_verified_user()
      {:ok, _} = Principals.claim(c.id, token, claimer)

      # Same principal, same empty ledger, and now fundable — because the
      # account that claimed it is what answers.
      assert :ok = Fountain.Billing.check_spend(c.user_id)
    end
  end

  describe "budget exhaustion" do
    test "is stamped once on the grant when the gate first refuses" do
      app = application_account()
      %{claimable: c} = open(app, %{"limits" => %{"max_cost_usd" => 1}})

      Credits.debit(c.user_id, 100, "burn_turn", idempotency_key: "drain:#{c.user_id}")

      assert {:error, :insufficient_credits} = Fountain.Billing.check_spend(c.user_id)
      stamped = Repo.get(ClaimableUser, c.id).budget_exhausted_at
      assert stamped

      # A second refusal does not move the stamp: this runs at every door.
      assert {:error, :insufficient_credits} = Fountain.Billing.check_spend(c.user_id)
      assert Repo.get(ClaimableUser, c.id).budget_exhausted_at == stamped
    end
  end

  describe "release/2 and expire_due/1" do
    test "release revokes the credential and refunds the unspent grant" do
      app = application_account()
      %{claimable: c, api_key: raw} = open(app, %{"limits" => %{"max_cost_usd" => 1}})
      after_grant = Credits.balance(app.id)

      Credits.debit(c.user_id, 40, "burn_turn", idempotency_key: "spent:#{c.user_id}")

      {:ok, released} = Principals.release(c)

      assert released.status == "released"
      assert released.released_at
      assert {:error, :revoked} = Accounts.authenticate_api_key(raw)
      # Only the unspent 60 comes back; work already done stays paid for.
      assert Credits.balance(app.id) == after_grant + 60
      # And it left the principal, rather than existing in two balances. Zero,
      # not -40: the burn already came out of the balance, so what settles is
      # the 60 the lot still held.
      assert Credits.balance(c.user_id) == 0
    end

    test "a fully spent grant settles cleanly and hands back nothing" do
      app = application_account()
      %{claimable: c} = open(app, %{"limits" => %{"max_cost_usd" => 1}})
      after_grant = Credits.balance(app.id)

      Credits.debit(c.user_id, 100, "burn_turn", idempotency_key: "all:#{c.user_id}")

      {:ok, released} = Principals.release(c)

      # The lot is at zero, so `expire_lot/2` says `{:ok, :nothing}` rather
      # than handing back an entry. Reading that as a refund used to raise
      # into a rescue, which looked identical to a settle that worked.
      assert released.status == "released"
      assert Credits.balance(app.id) == after_grant
      assert Credits.balance(c.user_id) == 0
    end

    test "settling twice hands the money back once" do
      app = application_account()
      %{claimable: c} = open(app, %{"limits" => %{"max_cost_usd" => 1}})
      after_grant = Credits.balance(app.id)

      {:ok, _} = Principals.release(c)
      assert Credits.balance(app.id) == after_grant + 100

      # Idempotent by ledger key on both halves, so a retry of the teardown
      # cannot pay the application twice for one grant.
      Principals.release(Repo.get(ClaimableUser, c.id))
      assert Credits.balance(app.id) == after_grant + 100
    end

    test "a claim settles the grant back to the application" do
      app = application_account()
      %{claimable: c, claim_token: token} = open(app, %{"limits" => %{"max_cost_usd" => 1}})
      after_grant = Credits.balance(app.id)

      Credits.debit(c.user_id, 30, "burn_turn", idempotency_key: "spent:#{c.user_id}")

      {:ok, _} = Principals.claim(c.id, token, insert_verified_user())

      # After a claim the gate reads the owner's balance, so an unspent grant
      # left on the principal is money nobody can spend and nobody got back.
      assert Credits.balance(app.id) == after_grant + 70
      assert Credits.balance(c.user_id) == 0
    end

    test "a claimed principal is not the application's to release" do
      app = application_account()
      %{claimable: c, claim_token: token} = open(app)
      {:ok, _} = Principals.claim(c.id, token, insert_verified_user())

      assert {:error, :already_claimed} = Principals.release(Repo.get(ClaimableUser, c.id))
    end

    test "expire_due closes only unclaimed grants past their date" do
      app = application_account()
      %{claimable: due} = open(app)
      %{claimable: live} = open(app)
      %{claimable: claimed, claim_token: token} = open(app)

      {:ok, _} = Principals.claim(claimed.id, token, insert_verified_user())

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      for c <- [due, claimed] do
        Repo.get(ClaimableUser, c.id) |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()
      end

      assert Principals.expire_due() == 1
      assert Repo.get(ClaimableUser, due.id).status == "expired"
      assert Repo.get(ClaimableUser, live.id).status == "unclaimed"
      # An expiry never reaches a machine somebody owns.
      assert Repo.get(ClaimableUser, claimed.id).status == "claimed"
    end

    test "an expired grant stays readable so a lost response can be reconciled" do
      app = application_account()
      %{claimable: c} = open(app)

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      Repo.get(ClaimableUser, c.id) |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()
      Principals.expire_due()

      assert %ClaimableUser{status: "expired"} = Principals.get_claimable_for(c.id, app.id)
    end

    test "purge_closed deletes the principal once the retention window passes" do
      app = application_account()
      %{claimable: c} = open(app)
      {:ok, released} = Principals.release(c)

      long_ago = DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.truncate(:second)
      released |> Ecto.Changeset.change(released_at: long_ago) |> Repo.update!()

      assert Principals.purge_closed() == 1
      refute Accounts.get_user(c.user_id)
      refute Repo.get(ClaimableUser, c.id)
    end
  end

  describe "deleting an owner" do
    test "takes the principals it owns with it" do
      app = application_account()
      %{claimable: c, claim_token: token} = open(app)
      claimer = insert_verified_user()
      {:ok, _} = Principals.claim(c.id, token, claimer)

      {:ok, _} = Fountain.Accounts.Deletion.delete_user(claimer)

      # Otherwise: a tenant with resources, no owner, no working credential
      # and no sweep that would ever find it.
      refute Accounts.get_user(c.user_id)
      refute Repo.get(ClaimableUser, c.id)
    end
  end

  describe "get_claimable_for/2" do
    test "is visible to the application and the claimer, and to nobody else" do
      app = application_account()
      %{claimable: c, claim_token: token} = open(app)
      claimer = insert_verified_user()
      stranger = insert_verified_user()

      {:ok, _} = Principals.claim(c.id, token, claimer)

      assert Principals.get_claimable_for(c.id, app.id)
      assert Principals.get_claimable_for(c.id, claimer.id)
      # Not a 403: an id that reads as absent cannot be probed for existence.
      refute Principals.get_claimable_for(c.id, stranger.id)
    end
  end

  describe "the unverified-account pruner" do
    test "never deletes a principal, however old" do
      app = application_account()
      %{claimable: c} = open(app)

      long_ago = DateTime.utc_now() |> DateTime.add(-365, :day) |> DateTime.truncate(:second)

      from(u in Fountain.Accounts.User, where: u.id == ^c.user_id)
      |> Repo.update_all(set: [inserted_at: long_ago])

      Fountain.Workers.UnverifiedAccountPruner.perform(%Oban.Job{args: %{}})

      assert Accounts.get_user(c.user_id)
    end
  end
end
