defmodule Managoat.OAuth.DeviceTest do
  use Managoat.OAuth.Case, async: true

  describe "device authorization" do
    test "the happy path: start → approve → poll mints the host's token, once" do
      subject = subject()

      assert {:ok, %{device_code: device_code, user_code: user_code} = grant} =
               TestInstance.start_device_grant()

      assert grant.expires_in == 900
      assert grant.interval == TestInstance.device_interval_seconds()
      assert grant.interval == 5
      # The display shape a human types back in, dash and all.
      assert user_code =~ ~r/^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$/
      # Starting is unaudited: nothing has happened to any subject yet.
      refute_received {:audit, _, _, _}

      # Nobody has decided yet.
      assert {:error, :authorization_pending} = TestInstance.poll_device_grant(device_code)
      refute_received {:subject_allowed?, _}

      # The approval page finds it however the human typed it.
      assert {:ok, %DeviceGrant{subject_id: nil}} =
               TestInstance.get_device_grant_for_approval(String.downcase(user_code))

      assert :ok = TestInstance.approve_device_grant(user_code, subject, actor: "ui")

      assert_received {:audit, :device_approved, %{subject_id: ^subject, grant_id: grant_id},
                       [actor: "ui"]}

      assert is_binary(grant_id)

      assert {:ok, %{access_token: token, api_key: minted}} =
               TestInstance.poll_device_grant(device_code, actor: "api")

      assert token == "tok-" <> subject
      # Asked in order: may the subject collect, then mint a device token
      # with no client and no expiry.
      assert_received {:subject_allowed?, ^subject}

      assert_received {:issue_token, ^subject,
                       %{type: :device, id: ^grant_id, client_id: nil, expires_at: nil},
                       [actor: "api"]}

      assert minted.subject == subject

      # Single use: the grant is consumed with the mint.
      assert {:error, :invalid_grant} = TestInstance.poll_device_grant(device_code)
      refute_received {:issue_token, _, _, _}
    end

    test "polling faster than the interval gets slow_down" do
      {:ok, %{device_code: device_code}} = TestInstance.start_device_grant()

      assert {:error, :authorization_pending} = TestInstance.poll_device_grant(device_code)
      assert {:error, :slow_down} = TestInstance.poll_device_grant(device_code)
    end

    test "a denial reaches the poller as access_denied and audits" do
      subject = subject()
      {:ok, %{device_code: device_code, user_code: user_code}} = TestInstance.start_device_grant()

      assert :ok = TestInstance.deny_device_grant(user_code, subject, actor: "ui")
      assert_received {:audit, :device_denied, %{subject_id: ^subject}, [actor: "ui"]}
      assert {:error, :access_denied} = TestInstance.poll_device_grant(device_code)
      refute_received {:subject_allowed?, _}

      # Decided is decided: no second opinion, in either direction.
      assert {:error, :not_found} = TestInstance.approve_device_grant(user_code, subject)
      assert {:error, :not_found} = TestInstance.get_device_grant_for_approval(user_code)
    end

    test "an expired grant is expired_token to the poll, invisible to approval, and pruned" do
      subject = subject()
      {:ok, %{device_code: device_code, user_code: user_code}} = TestInstance.start_device_grant()

      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      TestRepo.update_all(DeviceGrant, set: [expires_at: past])

      assert {:error, :expired_token} = TestInstance.poll_device_grant(device_code)
      assert {:error, :not_found} = TestInstance.get_device_grant_for_approval(user_code)
      assert {:error, :not_found} = TestInstance.approve_device_grant(user_code, subject)
      assert TestInstance.prune_expired() >= 1
      assert TestRepo.aggregate(DeviceGrant, :count) == 0
    end

    test "an unknown device code is invalid_grant" do
      assert {:error, :invalid_grant} = TestInstance.poll_device_grant("not-a-code")
    end

    # The ordering rule, kept on purpose: the host is asked about the
    # subject before the grant is consumed, so a refusal leaves the grant
    # approved and pollable rather than spent.
    test "a subject the host refuses gets access_denied and the grant is not consumed" do
      subject = subject()
      {:ok, %{device_code: device_code, user_code: user_code}} = TestInstance.start_device_grant()
      assert :ok = TestInstance.approve_device_grant(user_code, subject)

      Recording.refuse_subject(:suspended)
      assert {:error, :access_denied} = TestInstance.poll_device_grant(device_code)
      assert_received {:subject_allowed?, ^subject}
      refute_received {:issue_token, _, _, _}

      assert %DeviceGrant{approved_at: %DateTime{}, used_at: nil, subject_id: ^subject} =
               TestRepo.get_by!(DeviceGrant,
                 user_code: TestInstance.normalize_user_code(user_code)
               )

      # The state that changed can change back; the grant is still there.
      Recording.reset()
      assert {:ok, %{access_token: token}} = TestInstance.poll_device_grant(device_code)
      assert token == "tok-" <> subject
    end

    test "a mint the host cannot complete is :server_error, and the grant is consumed" do
      subject = subject()
      {:ok, %{device_code: device_code, user_code: user_code}} = TestInstance.start_device_grant()
      assert :ok = TestInstance.approve_device_grant(user_code, subject)

      Recording.fail_issue(:database_down)
      assert {:error, :server_error} = TestInstance.poll_device_grant(device_code)
      assert_received {:issue_token, ^subject, %{type: :device}, _}

      Recording.reset()
      assert {:error, :invalid_grant} = TestInstance.poll_device_grant(device_code)
    end

    test "an approved grant bound to no subject is refused as invalid_grant" do
      subject = subject()
      {:ok, %{device_code: device_code, user_code: user_code}} = TestInstance.start_device_grant()
      assert :ok = TestInstance.approve_device_grant(user_code, subject)

      # A row edited by hand: approval and subject are written in one update.
      TestRepo.update_all(DeviceGrant, set: [subject_id: nil])

      assert {:error, :invalid_grant} = TestInstance.poll_device_grant(device_code)
      refute_received {:subject_allowed?, _}
    end

    test "approve writes the subject into the user_id column" do
      subject = subject()
      {:ok, %{user_code: user_code}} = TestInstance.start_device_grant()
      assert :ok = TestInstance.approve_device_grant(user_code, subject)

      %{rows: [[stored]]} = TestRepo.query!("SELECT user_id::text FROM oauth_device_grants")
      assert stored == subject
    end

    test "normalize_user_code strips the display shape; format puts it back" do
      assert TestInstance.normalize_user_code(" bcdf-ghjk ") == "BCDFGHJK"
      assert TestInstance.format_user_code("BCDFGHJK") == "BCDF-GHJK"
      assert TestInstance.format_user_code("odd") == "odd"
    end
  end
end
