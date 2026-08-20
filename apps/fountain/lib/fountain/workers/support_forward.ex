defmodule Fountain.Workers.SupportForward do
  @moduledoc """
  Deliver one support report to the operator: a GitHub issue when
  `SUPPORT_GITHUB_REPO` + `SUPPORT_GITHUB_TOKEN` are configured, and/or an
  email to `SUPPORT_EMAIL`. Either target succeeding marks the report
  `forwarded` (with the issue URL when there is one); neither configured is
  not an error — the report is still on the row for `GET /api/support/reports`
  and the admin to read — and the job completes. A transport failure retries
  (three attempts), then the row carries `forward_error`.
  """
  use Oban.Worker, queue: :mailer, max_attempts: 3, unique: [keys: [:report_id], period: 3600]

  require Logger
  import Swoosh.Email

  alias Fountain.{Accounts, Mailer, Support}
  alias Fountain.Support.Report

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"report_id" => id}}) do
    case Support._unsafe_get_report(id) do
      nil ->
        :ok

      %Report{status: "forwarded"} ->
        :ok

      %Report{} = report ->
        targets = Support.targets()
        user = report.user_id && Accounts.get_user(report.user_id)

        results = [
          targets.github && github(report, user, targets.github),
          targets.email && email(report, user, targets.email)
        ]

        outcomes = Enum.reject(results, &is_nil/1)

        url =
          Enum.find_value(outcomes, fn
            {:ok, u} -> u
            _ -> nil
          end)

        errors = for {:error, e} <- outcomes, do: e

        cond do
          outcomes == [] ->
            # nothing configured: the row is the inbox
            {:ok, _} = Support.mark_forwarded(report, %{status: "forwarded", forwarded_at: now()})
            :ok

          Enum.any?(outcomes, &match?({:ok, _}, &1)) ->
            {:ok, _} =
              Support.mark_forwarded(report, %{
                status: "forwarded",
                forwarded_at: now(),
                external_url: url,
                forward_error: if(errors == [], do: nil, else: Enum.join(errors, "; "))
              })

            :ok

          true ->
            msg = Enum.join(errors, "; ")
            {:ok, _} = Support.mark_forwarded(report, %{status: "failed", forward_error: msg})
            {:error, msg}
        end
    end
  end

  # ── targets ───────────────────────────────────────────────────────────────

  @doc false
  def github(%Report{} = r, user, {repo, token}, request \\ &Req.post/2) do
    title = "[#{r.category}] #{first_line(r.message)}"
    body = issue_body(r, user)

    case request.("https://api.github.com/repos/#{repo}/issues",
           json: %{title: title, body: body, labels: ["support", r.category]},
           headers: [
             {"authorization", "Bearer #{token}"},
             {"accept", "application/vnd.github+json"},
             {"x-github-api-version", "2022-11-28"}
           ],
           receive_timeout: 15_000
         ) do
      {:ok, %Req.Response{status: 201, body: %{"html_url" => url}}} -> {:ok, url}
      {:ok, %Req.Response{status: status}} -> {:error, "github #{status}"}
      {:error, reason} -> {:error, "github: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "github: #{Exception.message(e)}"}
  end

  @doc false
  def email(%Report{} = r, user, to) do
    mail =
      new()
      |> from(Fountain.Emails.UserEmails.from_address())
      |> to(to)
      |> subject("[Fountain support] [#{r.category}] #{first_line(r.message)}")
      |> text_body(issue_body(r, user))
      |> maybe_attach(r)

    case Mailer.deliver(mail) do
      {:ok, _} -> {:ok, nil}
      {:error, reason} -> {:error, "email: #{inspect(reason)}"}
    end
  end

  defp maybe_attach(mail, %Report{screenshot: bin, screenshot_media_type: mt})
       when is_binary(bin) do
    ext = mt |> String.split("/") |> List.last()

    attachment(
      mail,
      Swoosh.Attachment.new({:data, bin}, filename: "screenshot.#{ext}", content_type: mt)
    )
  end

  defp maybe_attach(mail, _), do: mail

  @doc false
  def issue_body(%Report{} = r, user) do
    base = Fountain.PublicUrl.base()
    who = if user, do: "#{user.email} (`#{user.id}`)", else: "(account deleted)"
    ctx = r.context || %{}

    """
    **From:** #{who}
    **Client:** #{r.client || "—"} · **Filed:** #{r.inserted_at} · **Report:** `#{r.id}`
    **Category:** #{r.category}

    #{r.message}

    ---
    #{context_lines(ctx, base)}
    <details><summary>Full context</summary>

    ```json
    #{Jason.encode!(ctx, pretty: true)}
    ```
    </details>
    #{if is_binary(r.screenshot), do: "\nScreenshot: attached to the report (#{r.screenshot_media_type}).", else: ""}
    """
  end

  defp context_lines(ctx, base) do
    [
      ctx["conversation_id"] &&
        "**Conversation:** #{conversation_link(ctx["conversation_id"], base)} (`#{ctx["conversation_id"]}`)",
      ctx["agent_id"] &&
        "**Agent:** #{ctx["agent_name"] || ""} `#{ctx["agent_id"]}` · #{ctx["runtime"] || ""} #{ctx["model"] || ""}",
      ctx["sandbox"] && "**Sandbox:** `#{inspect(ctx["sandbox"])}`",
      ctx["presence"] && "**Presence:** #{inspect(ctx["presence"])}",
      ctx["url"] && "**Page:** #{ctx["url"]}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  # The transcript lives in the conversations app, not in Fountain's console;
  # a deployment without one gets the API URL, which is at least fetchable.
  defp conversation_link(id, base) do
    Fountain.Apps.conversation_url(id) || "#{base}/api/conversations/#{id}"
  end

  defp first_line(message) do
    message |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 90)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
