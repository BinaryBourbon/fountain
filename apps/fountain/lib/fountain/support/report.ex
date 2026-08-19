defmodule Fountain.Support.Report do
  @moduledoc """
  A problem report a user filed from a client — the "Report a problem" button
  in fountain-team, or `POST /api/support/reports` from anything else. Carries
  what the client knew at the time (conversation, agent, sandbox, presence,
  recent events, app version) so triage starts with the facts, and an optional
  screenshot. Forwarded to the operator by `Fountain.Workers.SupportForward`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @categories ~w(bug stuck question idea other)
  @statuses ~w(new forwarded failed)
  @max_message 20_000
  @max_context_bytes 64 * 1024
  @max_screenshot 5 * 1024 * 1024
  @image_types ~w(image/png image/jpeg image/gif image/webp)

  schema "support_reports" do
    belongs_to :user, Fountain.Accounts.User
    field :category, :string
    field :message, :string
    field :context, :map, default: %{}
    field :client, :string
    field :screenshot, :binary, redact: true
    field :screenshot_media_type, :string
    field :status, :string, default: "new"
    field :forwarded_at, :utc_datetime
    field :external_url, :string
    field :forward_error, :string

    timestamps(type: :utc_datetime)
  end

  def categories, do: @categories

  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :user_id,
      :category,
      :message,
      :context,
      :client,
      :screenshot,
      :screenshot_media_type
    ])
    |> update_change(:message, &String.trim/1)
    |> validate_required([:user_id, :category, :message])
    |> validate_inclusion(:category, @categories)
    |> validate_length(:message, min: 1, max: @max_message)
    |> validate_length(:client, max: 200)
    |> validate_context()
    |> validate_screenshot()
  end

  def forward_changeset(report, attrs) do
    report
    |> cast(attrs, [:status, :forwarded_at, :external_url, :forward_error])
    |> validate_inclusion(:status, @statuses)
  end

  defp validate_context(cs) do
    case get_change(cs, :context) do
      nil ->
        cs

      ctx when is_map(ctx) ->
        if byte_size(Jason.encode!(ctx)) > @max_context_bytes,
          do: add_error(cs, :context, "is too large (64 KB max)"),
          else: cs

      _ ->
        add_error(cs, :context, "must be an object")
    end
  end

  defp validate_screenshot(cs) do
    case {get_field(cs, :screenshot), get_field(cs, :screenshot_media_type)} do
      {nil, _} ->
        put_change(cs, :screenshot_media_type, nil)

      {bin, mt} when is_binary(bin) ->
        cs
        |> then(fn c ->
          if byte_size(bin) > @max_screenshot,
            do: add_error(c, :screenshot, "exceeds the 5 MB limit"),
            else: c
        end)
        |> then(fn c ->
          if mt in @image_types,
            do: c,
            else:
              add_error(
                c,
                :screenshot_media_type,
                "must be one of #{Enum.join(@image_types, ", ")}"
              )
        end)
    end
  end
end
