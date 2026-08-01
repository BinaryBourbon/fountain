defmodule Fountain.Emails.UserEmailsTest do
  use Fountain.DataCase, async: true

  import Swoosh.TestAssertions

  alias Fountain.Emails.UserEmails

  describe "deliver_verification_email/2" do
    test "delivers an email with the correct subject to the user" do
      user = insert_verified_user()

      assert {:ok, _email} = UserEmails.deliver_verification_email(user, "test_token_abc123")

      assert_email_sent(subject: "Verify your Fountain account", to: [{user.email, user.email}])
    end

    test "email body contains the verification token" do
      user = insert_verified_user()
      token = "unique_verification_token"

      assert {:ok, _email} = UserEmails.deliver_verification_email(user, token)

      assert_email_sent(fn email ->
        assert email.subject == "Verify your Fountain account"
        assert email.html_body =~ token
        assert email.text_body =~ token
      end)
    end

    test "email body contains confirmation URL path" do
      user = insert_verified_user()
      token = "path_token_xyz"

      assert {:ok, _email} = UserEmails.deliver_verification_email(user, token)

      assert_email_sent(fn email ->
        assert email.html_body =~ "/users/confirm/#{token}"
        assert email.text_body =~ "/users/confirm/#{token}"
      end)
    end
  end

  describe "link absoluteness" do
    # These assert on the scheme, not just the path. The original tests only
    # checked "/users/confirm/<token>", which passed happily while production
    # was emitting "fountain.inevitable.fyi/users/confirm/<token>" — a string
    # no mail client will render as a link.
    setup do
      original = Application.get_env(:fountain, :public_url)
      on_exit(fn -> Application.put_env(:fountain, :public_url, original) end)
      :ok
    end

    test "verification link is absolute even if :public_url is set to a bare host" do
      Application.put_env(:fountain, :public_url, "fountain.example.com")
      user = insert_verified_user()

      assert {:ok, _} = UserEmails.deliver_verification_email(user, "tok")

      assert_email_sent(fn email ->
        assert email.html_body =~ "https://fountain.example.com/users/confirm/tok"
        assert email.text_body =~ "https://fountain.example.com/users/confirm/tok"
      end)
    end

    test "reset link is absolute even if :public_url is set to a bare host" do
      Application.put_env(:fountain, :public_url, "fountain.example.com")
      user = insert_verified_user()

      assert {:ok, _} = UserEmails.deliver_password_reset_email(user, "tok")

      assert_email_sent(fn email ->
        assert email.html_body =~ "https://fountain.example.com/auth/reset/tok"
        assert email.text_body =~ "https://fountain.example.com/auth/reset/tok"
      end)
    end

    test "an absolute :public_url is preserved verbatim" do
      Application.put_env(:fountain, :public_url, "https://custom.example.org")
      user = insert_verified_user()

      assert {:ok, _} = UserEmails.deliver_verification_email(user, "tok")

      assert_email_sent(fn email ->
        assert email.html_body =~ "https://custom.example.org/users/confirm/tok"
      end)
    end
  end

  describe "deliver_password_reset_email/2" do
    test "delivers an email with the correct subject to the user" do
      user = insert_verified_user()

      assert {:ok, _email} = UserEmails.deliver_password_reset_email(user, "reset_token_abc")

      assert_email_sent(subject: "Reset your Fountain password", to: [{user.email, user.email}])
    end

    test "email body contains the reset token" do
      user = insert_verified_user()
      token = "unique_reset_token"

      assert {:ok, _email} = UserEmails.deliver_password_reset_email(user, token)

      assert_email_sent(fn email ->
        assert email.subject == "Reset your Fountain password"
        assert email.html_body =~ token
        assert email.text_body =~ token
      end)
    end

    test "email body contains password reset URL path" do
      user = insert_verified_user()
      token = "reset_path_token"

      assert {:ok, _email} = UserEmails.deliver_password_reset_email(user, token)

      assert_email_sent(fn email ->
        assert email.html_body =~ "/auth/reset/#{token}"
        assert email.text_body =~ "/auth/reset/#{token}"
      end)
    end
  end
end
