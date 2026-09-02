defmodule Managoat.OAuth.CodesTest do
  use Managoat.OAuth.Case, async: true

  import Ecto.Query

  describe "authorize/3 + exchange/2" do
    test "the happy path: a code, consumed once for the token the host mints" do
      subject = subject()
      {verifier, challenge} = pkce()

      assert {:ok, code} =
               TestInstance.authorize(subject, request(challenge),
                 actor: "ui",
                 request_ip: "1.1.1.1"
               )

      assert is_binary(code) and byte_size(code) > 20

      # The consent was audited through the host, with the caller's opts untouched.
      assert_received {:audit, :authorized,
                       %{subject_id: ^subject, client_id: "test-app", redirect_uri: redirect},
                       [actor: "ui", request_ip: "1.1.1.1"]}

      assert redirect == redirect()

      assert {:ok, %{access_token: token, expires_in: ttl, api_key: minted}} =
               TestInstance.exchange(token_request(code, verifier), actor: "self")

      assert token == "tok-" <> subject
      assert ttl == TestInstance.token_ttl_seconds()
      assert ttl == 30 * 24 * 3600

      # The host was asked for a code-grant token with the library's lifetime.
      assert_received {:issue_token, ^subject,
                       %{
                         type: :authorization_code,
                         id: code_id,
                         client_id: "test-app",
                         expires_at: exp
                       }, [actor: "self"]}

      assert is_binary(code_id)
      assert_in_delta DateTime.diff(exp, DateTime.utc_now()), ttl, 5

      assert minted == %{
               subject: subject,
               grant: %{
                 type: :authorization_code,
                 id: code_id,
                 client_id: "test-app",
                 expires_at: exp
               }
             }

      # Single use.
      assert {:error, :invalid_grant} = TestInstance.exchange(token_request(code, verifier))
      refute_received {:issue_token, _, _, _}
    end

    test "every wrong grant is one answer, and none of them consumes the code" do
      subject = subject()
      {verifier, challenge} = pkce()
      {:ok, code} = TestInstance.authorize(subject, request(challenge))
      base = token_request(code, verifier)

      assert {:error, :invalid_grant} =
               TestInstance.exchange(%{base | "code_verifier" => verifier <> "x"})

      assert {:error, :invalid_grant} = TestInstance.exchange(%{base | "client_id" => "other"})

      assert {:error, :invalid_grant} =
               TestInstance.exchange(%{base | "redirect_uri" => "http://localhost:5173/"})

      assert {:error, :invalid_grant} = TestInstance.exchange(%{base | "code" => "not-a-code"})
      assert {:error, :invalid_grant} = TestInstance.exchange(Map.delete(base, "code_verifier"))
      assert {:error, :invalid_grant} = TestInstance.exchange(Map.delete(base, "code"))
      refute_received {:issue_token, _, _, _}

      # None of those consumed the code.
      assert {:ok, _} = TestInstance.exchange(base)
    end

    test "an invalid authorization request issues nothing and audits nothing" do
      {_v, challenge} = pkce()

      assert {:error, :unknown_client} =
               TestInstance.authorize(subject(), request(challenge, %{"client_id" => "nope"}))

      refute_received {:audit, _, _, _}
      assert TestRepo.aggregate(AuthorizationCode, :count) == 0
    end

    test "an expired code is refused and pruned" do
      subject = subject()
      {verifier, challenge} = pkce()
      {:ok, code} = TestInstance.authorize(subject, request(challenge))

      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      TestRepo.update_all(AuthorizationCode, set: [expires_at: past])

      assert {:error, :invalid_grant} = TestInstance.exchange(token_request(code, verifier))
      assert TestInstance.prune_expired() >= 1
      assert TestRepo.aggregate(AuthorizationCode, :count) == 0
    end

    # The ordering rule, kept on purpose: the code is consumed before the
    # host mints, so a failed mint is :server_error with the code spent. A
    # CLI and two SPAs rely on this answer.
    test "a mint the host cannot complete is :server_error, and the code is consumed" do
      subject = subject()
      {verifier, challenge} = pkce()
      {:ok, code} = TestInstance.authorize(subject, request(challenge))

      Recording.fail_issue(:database_down)
      assert {:error, :server_error} = TestInstance.exchange(token_request(code, verifier))
      assert_received {:issue_token, ^subject, %{type: :authorization_code}, _}

      # Spent: the row is marked used, and a retry with the host healthy again
      # is a second exchange of a used code.
      assert [%AuthorizationCode{used_at: %DateTime{}}] =
               TestRepo.all(from(c in AuthorizationCode, where: c.subject_id == ^subject))

      Recording.reset()
      assert {:error, :invalid_grant} = TestInstance.exchange(token_request(code, verifier))
    end

    test "the stored row carries the subject in the user_id column, hashed code only" do
      subject = subject()
      {_verifier, challenge} = pkce()
      {:ok, code} = TestInstance.authorize(subject, request(challenge))

      %{rows: [[stored_subject, code_hash]]} =
        TestRepo.query!("SELECT user_id::text, code_hash FROM oauth_authorization_codes")

      assert stored_subject == subject
      assert code_hash != code
      assert code_hash == Base.encode16(:crypto.hash(:sha256, code), case: :lower)
    end
  end

  test "pkce_verify/2 is S256 and total" do
    {v, c} = pkce()
    assert TestInstance.pkce_verify(v, c)
    refute TestInstance.pkce_verify(v <> "a", c)
    refute TestInstance.pkce_verify(nil, c)
    refute TestInstance.pkce_verify(v, nil)
    refute TestInstance.pkce_verify(v, "short")
  end
end
