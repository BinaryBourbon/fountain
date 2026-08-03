defmodule FountainWeb.AdminLive.Helpers do
  @moduledoc """
  Formatting and badge-color helpers shared by the admin LiveViews.

  Extracted from `AdminLive.Index` when the per-user and per-conversation
  detail views arrived (#446) so the three pages render dates and status
  badges identically.
  """

  def subscription_status_color("active"), do: "bg-green-100 text-green-800 border-green-200"
  def subscription_status_color("trialing"), do: "bg-blue-100 text-blue-800 border-blue-200"
  def subscription_status_color("comped"), do: "bg-purple-100 text-purple-800 border-purple-200"
  def subscription_status_color("past_due"), do: "bg-amber-100 text-amber-800 border-amber-200"
  def subscription_status_color(_), do: "bg-zinc-100 text-zinc-500 border-zinc-200"

  def sandbox_status_color("running"), do: "bg-blue-100 text-blue-800 border-blue-200"
  def sandbox_status_color("ready"), do: "bg-green-100 text-green-800 border-green-200"
  def sandbox_status_color("failed"), do: "bg-red-100 text-red-700 border-red-200"
  def sandbox_status_color(_), do: "bg-zinc-100 text-zinc-500 border-zinc-200"

  def conversation_status_color("running"), do: "bg-blue-100 text-blue-800 border-blue-200"
  def conversation_status_color("completed"), do: "bg-green-100 text-green-800 border-green-200"
  def conversation_status_color("failed"), do: "bg-red-100 text-red-700 border-red-200"
  def conversation_status_color(_), do: "bg-zinc-100 text-zinc-500 border-zinc-200"

  def format_date(nil), do: ""
  def format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  def format_ts(nil), do: ""
  def format_ts(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end
