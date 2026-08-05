defmodule FountainWeb.VerifyPendingLiveTest do
  use FountainWeb.ConnCase, async: true
  use Oban.Testing, repo: Fountain.Repo

  import Phoenix.LiveViewTest

  alias Fountain.Accounts
  alias Fountain.Repo
  alias Fountain.Workers.VerificationEmail

  setup %{conn: conn} do
    user = insert_user()
    %{conn: login_user(conn, user), user: user}
  end

  describe "the waiting page" do
    test "names the address the link was sent to", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/auth/verify-pending")

      assert html =~ "Check your email"
      assert html =~ user.email
    end

    test "offers a way out for someone who used the wrong address", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/auth/verify-pending")

      assert lv |> element("a[href='/auth/logout']") |> has_element?()
    end
  end

  describe "auto-advance" do
    test "verification elsewhere sends the page on without a second login", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/auth/verify-pending")

      # Stands in for the emailed link being clicked in another tab or on a
      # phone: verify_email/1 is what every verification route ends up calling.
      {:ok, _verified} = Accounts.verify_email(user)

      assert_redirect(lv, "/onboarding/step_1")
    end

    test "an onboarded user is advanced to the conversation list", %{conn: conn, user: user} do
      {:ok, user} =
        user
        |> Ecto.Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
        |> Repo.update()

      {:ok, lv, _html} = live(conn, ~p"/auth/verify-pending")

      {:ok, _verified} = Accounts.verify_email(user)

      assert_redirect(lv, "/conversations")
    end

    test "the poll advances even when the broadcast never arrives", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/auth/verify-pending")

      # Stamp the column directly, bypassing verify_email/1 — this is the
      # cross-node case where the PubSub message is emitted on another node
      # that this one is not clustered with.
      {:ok, _} =
        user
        |> Ecto.Changeset.change(email_verified_at: DateTime.utc_now(:second))
        |> Repo.update()

      send(lv.pid, :check_verification)

      assert_redirect(lv, "/onboarding/step_1")
    end

    test "a broadcast that does not match the database does not advance", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/auth/verify-pending")

      # The message is a trigger to re-read, never the evidence itself.
      Phoenix.PubSub.broadcast(
        Fountain.PubSub,
        Accounts.verification_topic(user.id),
        {:email_verified, user.id}
      )

      assert render(lv) =~ "Check your email"
    end
  end

  describe "resend" do
    test "enqueues a fresh verification email and says so", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/auth/verify-pending")

      html = lv |> element("button[phx-click='resend']") |> render_click()

      assert html =~ "on its way"
      assert_enqueued(worker: VerificationEmail, args: %{user_id: user.id})
    end

    test "refuses past the hourly budget instead of enqueueing forever", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/auth/verify-pending")

      # The bucket allows 5 an hour, keyed by user id. Oban's own 60s
      # uniqueness collapses the burst into a single job, so the count of jobs
      # says nothing here — the refusal on the sixth click is the assertion.
      for _ <- 1..5 do
        html = lv |> element("button[phx-click='resend']") |> render_click()
        assert html =~ "on its way"
      end

      html = lv |> element("button[phx-click='resend']") |> render_click()
      assert html =~ "lot of resends"
    end
  end
end
