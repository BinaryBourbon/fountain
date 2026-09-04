defmodule FountainSupport.ReportJSON do
  @moduledoc false

  alias FountainSupport.Report

  def index(%{reports: reports}), do: %{data: Enum.map(reports, &data/1)}
  def show(%{report: report}), do: %{data: data(report)}

  @doc "One report; the screenshot is reported by presence and type, never inlined."
  def data(%Report{} = r) do
    %{
      id: r.id,
      category: r.category,
      message: r.message,
      context: r.context,
      client: r.client,
      has_screenshot: is_binary(r.screenshot),
      screenshot_media_type: r.screenshot_media_type,
      status: r.status,
      forwarded_at: r.forwarded_at,
      external_url: r.external_url,
      forward_error: r.forward_error,
      inserted_at: r.inserted_at
    }
  end
end
