defmodule FountainWeb.CoreComponents do
  @moduledoc """
  A tiny set of UI components — buttons, inputs, flash messages — used
  across the LiveView pages.
  """
  use Phoenix.Component

  @doc "Flash messages from the conn or the LiveView socket."
  attr :flash, :map, default: %{}

  def flash_group(assigns) do
    ~H"""
    <div class="fixed top-2 right-2 z-50 space-y-2">
      <div :if={Phoenix.Flash.get(@flash, :info)}
        class="rounded bg-emerald-600/90 text-white px-4 py-2 shadow"
        phx-click="lv:clear-flash" phx-value-key="info">
        {Phoenix.Flash.get(@flash, :info)}
      </div>
      <div :if={Phoenix.Flash.get(@flash, :error)}
        class="rounded bg-rose-600/90 text-white px-4 py-2 shadow"
        phx-click="lv:clear-flash" phx-value-key="error">
        {Phoenix.Flash.get(@flash, :error)}
      </div>
    </div>
    """
  end

  attr :type, :string, default: "button"
  attr :class, :string, default: ""

  attr :rest, :global,
    include: ~w(disabled form name value phx-click phx-disable-with phx-value-id)

  slot :inner_block, required: true

  def btn(assigns) do
    ~H"""
    <button type={@type} class={[
      "inline-flex items-center gap-1 rounded-md px-3 py-1.5 text-sm font-medium",
      "bg-zinc-800 text-zinc-100 hover:bg-zinc-700 disabled:opacity-50",
      @class
    ]} {@rest}>{render_slot(@inner_block)}</button>
    """
  end

  attr :type, :string, default: "button"
  attr :class, :string, default: ""
  attr :rest, :global
  slot :inner_block, required: true

  def btn_secondary(assigns) do
    ~H"""
    <button type={@type} class={[
      "inline-flex items-center gap-1 rounded-md px-3 py-1.5 text-sm font-medium",
      "bg-zinc-100 text-zinc-700 hover:bg-zinc-200 border border-zinc-300",
      @class
    ]} {@rest}>{render_slot(@inner_block)}</button>
    """
  end

  attr :class, :string, default: ""
  attr :rest, :global
  slot :inner_block, required: true

  def btn_danger(assigns) do
    ~H"""
    <button class={[
      "inline-flex items-center gap-1 rounded-md px-3 py-1.5 text-sm font-medium",
      "bg-rose-600 text-white hover:bg-rose-700",
      @class
    ]} {@rest}>{render_slot(@inner_block)}</button>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :type, :string, default: "text"
  attr :value, :string, default: ""
  attr :placeholder, :string, default: nil
  attr :rest, :global, include: ~w(autofocus required disabled rows pattern phx-hook)

  def input(assigns) do
    ~H"""
    <div class="space-y-1">
      <label :if={@label} for={@id} class="block text-sm font-medium text-zinc-700">{@label}</label>
      <input :if={@type != "textarea"}
        type={@type} name={@name} id={@id} value={@value} placeholder={@placeholder}
        class="w-full rounded-md border-zinc-300 bg-white text-zinc-900 shadow-sm focus:border-zinc-500 focus:ring-zinc-500 px-3 py-2 border text-sm font-mono"
        {@rest}
      />
      <textarea :if={@type == "textarea"}
        name={@name} id={@id} placeholder={@placeholder}
        class="w-full rounded-md border-zinc-300 bg-white text-zinc-900 shadow-sm focus:border-zinc-500 focus:ring-zinc-500 px-3 py-2 border text-sm font-mono"
        {@rest}>{@value}</textarea>
    </div>
    """
  end

  attr :status, :string, required: true

  def status_badge(assigns) do
    color =
      case assigns.status do
        s when s in ["running", "starting", "ready"] -> "bg-emerald-100 text-emerald-800"
        s when s in ["pending"] -> "bg-amber-100 text-amber-800"
        s when s in ["completed", "idle"] -> "bg-zinc-100 text-zinc-700"
        s when s in ["failed"] -> "bg-rose-100 text-rose-800"
        s when s in ["terminated"] -> "bg-zinc-200 text-zinc-600"
        _ -> "bg-zinc-100 text-zinc-700"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={["inline-flex items-center px-2 py-0.5 rounded text-xs font-medium", @color]}>
      {@status}
    </span>
    """
  end
end
