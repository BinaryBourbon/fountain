defmodule Fountain.SupportTest do
  use Fountain.DataCase, async: true
  import Swoosh.TestAssertions

  alias Fountain.Support
  alias Fountain.Support.Report
  alias Fountain.Workers.SupportForward

  setup do
    %{user: insert_verified_user()}
  end

  describe "create_report/3" do
    test "stores the report, audits keys not content, enqueues the forwarder", %{user: user} do
      ctx = %{"conversation_id" => "c1", "agent_name" => "coo", "url" => "https://x/#/team/a"}

      assert {:ok, %Report{} = r} =
               Support.create_report(user.id, %{
                 "category" => "stuck",
                 "message" => "  teammate says starting forever  ",
                 "context" => ctx,
                 "client" => "fountain-team test"
               })

      assert r.message == "teammate says starting forever"
      assert r.status == "new"
      assert r.context == ctx
      assert_enqueued(worker: SupportForward, args: %{"report_id" => r.id})

      event =
        user.id
        |> Fountain.Audit.list_for_user()
        |> Enum.find(&(&1.action == "support.report.created"))

      assert event
      assert event.metadata["category"] == "stuck"
      assert event.metadata["context_keys"] == ["agent_name", "conversation_id", "url"]
      refute Jason.encode!(event.metadata) =~ "starting forever"
    end

    test "decodes a screenshot and refuses a bad one", %{user: user} do
      png = Base.encode64("not really a png but bytes")

      assert {:ok, %Report{screenshot: bin, screenshot_media_type: "image/png"}} =
               Support.create_report(user.id, %{
                 "category" => "bug",
                 "message" => "see attached",
                 "screenshot" => %{"data" => png, "media_type" => "image/png"}
               })

      assert is_binary(bin)

      assert {:error, {:screenshot, _}} =
               Support.create_report(user.id, %{
                 "category" => "bug",
                 "message" => "see attached",
                 "screenshot" => %{"data" => png, "media_type" => "image/svg+xml"}
               })
    end

    test "validates category and message", %{user: user} do
      assert {:error, %Ecto.Changeset{} = cs} =
               Support.create_report(user.id, %{"category" => "rant", "message" => ""})

      assert %{category: _, message: _} = errors_on(cs)
    end

    test "reports are tenant-scoped", %{user: user} do
      other = insert_verified_user()

      {:ok, r} =
        Support.create_report(user.id, %{"category" => "idea", "message" => "more pizza"})

      assert [%Report{id: id}] = Support.list_reports(user.id)
      assert id == r.id
      assert Support.list_reports(other.id) == []
      assert Support.get_report(r.id, other.id) == nil
    end
  end

  describe "SupportForward" do
    test "with nothing configured the report is marked forwarded (the row is the inbox)", %{
      user: user
    } do
      {:ok, r} = Support.create_report(user.id, %{"category" => "bug", "message" => "x"})
      assert :ok = perform_job(SupportForward, %{"report_id" => r.id})

      assert %Report{status: "forwarded", forwarded_at: %DateTime{}} =
               Support.get_report(r.id, user.id)
    end

    test "a GitHub target creates an issue with the context and records its URL", %{user: user} do
      {:ok, r} =
        Support.create_report(user.id, %{
          "category" => "bug",
          "message" => "first line\nmore detail",
          "context" => %{"conversation_id" => "c1", "agent_name" => "coo", "agent_id" => "a1"}
        })

      request = fn url, opts ->
        send(self(), {:github, url, opts})

        {:ok,
         %Req.Response{status: 201, body: %{"html_url" => "https://github.com/o/r/issues/7"}}}
      end

      assert {:ok, "https://github.com/o/r/issues/7"} =
               SupportForward.github(r, user, {"o/r", "tok"}, request)

      assert_received {:github, "https://api.github.com/repos/o/r/issues", opts}
      assert opts[:json].title == "[bug] first line"
      assert opts[:json].body =~ "coo"
      # The transcript link goes to the conversations app, not to a console
      # route that no longer exists (#866).
      assert opts[:json].body =~ Fountain.Apps.conversation_url("c1")
      assert opts[:json].body =~ user.email
      assert {"authorization", "Bearer tok"} in opts[:headers]
    end

    test "a GitHub failure is reported, not raised", %{user: user} do
      {:ok, r} = Support.create_report(user.id, %{"category" => "bug", "message" => "x"})
      request = fn _url, _opts -> {:ok, %Req.Response{status: 401, body: %{}}} end
      assert {:error, "github 401"} = SupportForward.github(r, user, {"o/r", "bad"}, request)
    end

    test "the email carries the body and the screenshot as an attachment", %{user: user} do
      png = Base.encode64("bytes")

      {:ok, r} =
        Support.create_report(user.id, %{
          "category" => "stuck",
          "message" => "stuck at starting",
          "screenshot" => %{"data" => png, "media_type" => "image/png"}
        })

      assert {:ok, nil} = SupportForward.email(r, user, "support@example.com")

      assert_email_sent(fn mail ->
        assert mail.subject =~ "[stuck] stuck at starting"
        assert [%Swoosh.Attachment{filename: "screenshot.png"}] = mail.attachments
        assert mail.text_body =~ user.email
      end)
    end
  end
end
