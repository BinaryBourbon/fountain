defmodule Fountain.Workers.EmailChangeEmailTest do
  use Fountain.DataCase, async: true

  import Swoosh.TestAssertions

  alias Fountain.Accounts
  alias Fountain.Workers.EmailChangeEmail

  describe "confirmation" do
    test "mails the NEW address a token that completes the change end to end" do
      user = insert_verified_user()

      assert :ok =
               perform_job(EmailChangeEmail, %{
                 "kind" => "confirmation",
                 "user_id" => user.id,
                 "new_email" => "next@example.com"
               })

      assert_email_sent(fn email ->
        assert email.subject == "Confirm your new Fountain email address"
        assert email.to == [{"next@example.com", "next@example.com"}]

        # The mailed artifact must be one apply_email_change/1 accepts.
        [_, token] =
          Regex.run(~r{/account/email/confirm/([A-Za-z0-9_\-\.]+)}, email.text_body)

        assert {:ok, updated, _old} = Accounts.apply_email_change(token)
        assert updated.email == "next@example.com"
      end)
    end

    test "stays silent when the address was claimed after the request" do
      user = insert_verified_user()
      insert_verified_user(%{"email" => "gone@example.com"})

      assert :ok =
               perform_job(EmailChangeEmail, %{
                 "kind" => "confirmation",
                 "user_id" => user.id,
                 "new_email" => "gone@example.com"
               })

      assert_no_email_sent()
    end

    test "is a no-op for a deleted user" do
      assert :ok =
               perform_job(EmailChangeEmail, %{
                 "kind" => "confirmation",
                 "user_id" => Ecto.UUID.generate(),
                 "new_email" => "x@example.com"
               })

      assert_no_email_sent()
    end
  end

  describe "notice" do
    test "tells the old address what the account's email became" do
      assert :ok =
               perform_job(EmailChangeEmail, %{
                 "kind" => "notice",
                 "old_email" => "was@example.com",
                 "new_email" => "now@example.com"
               })

      assert_email_sent(fn email ->
        assert email.to == [{"was@example.com", "was@example.com"}]
        assert email.subject == "Your Fountain email address was changed"
        assert email.text_body =~ "now@example.com"
        assert email.text_body =~ "can no longer be used to sign in"
      end)
    end
  end
end
