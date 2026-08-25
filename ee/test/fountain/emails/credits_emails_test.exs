defmodule Fountain.Emails.CreditsEmailsTest do
  use Fountain.DataCase, async: true

  import Swoosh.TestAssertions

  alias Fountain.Emails.CreditsEmails

  describe "deliver_welcome_email/1" do
    test "welcomes the user and points at the console" do
      user = insert_verified_user()

      assert {:ok, _email} = CreditsEmails.deliver_welcome_email(user)

      assert_email_sent(fn email ->
        assert email.subject == "Welcome to Fountain"
        assert email.to == [{user.email, user.email}]
        assert email.html_body =~ "/dashboard"
        assert email.text_body =~ "/dashboard"
      end)
    end

    test "links to the dashboard instead once onboarding is complete" do
      user = insert_verified_user()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, user} =
        user |> Ecto.Changeset.change(onboarding_completed_at: now) |> Repo.update()

      assert {:ok, _email} = CreditsEmails.deliver_welcome_email(user)

      assert_email_sent(fn email ->
        refute email.text_body =~ "/onboarding"
        assert email.subject == "Welcome to Fountain"
      end)
    end
  end
end
