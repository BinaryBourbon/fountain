defmodule FountainWeb.OnboardingLive.Wizard do
  use FountainWeb, :live_view

  alias Fountain.{Accounts, Agents, Conversations, Crypto, Environments, InferenceCredentials}
  alias Fountain.Environments.Environment
  alias Fountain.Agents.Agent
  alias Fountain.InferenceCredentials.Validator

  # ADR 0008 inserted "inference" as the new first step. Old step_1/2/3
  # shifted to step_2/3/4. Migration 20260510210001 bumps existing user
  # onboarding_state values.
  @steps ~w(step_1 step_2 step_3 step_4)

  @inference_providers [
    {:anthropic_api_key, "Anthropic", "console.anthropic.com"},
    {:claude_code_oauth_token, "Claude OAuth", "via 'claude setup-token'"},
    {:openai_api_key, "OpenAI", "platform.openai.com/api-keys"},
    {:gemini_api_key, "Gemini", "aistudio.google.com/apikey"}
  ]

  @impl true
  def mount(%{"step" => step}, _session, socket) when step in @steps do
    user = socket.assigns.current_user

    if user.onboarding_state == "completed" do
      {:ok, push_navigate(socket, to: ~p"/dashboard")}
    else
      {:ok, init_socket(socket, user, step)}
    end
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if user.onboarding_state == "completed" do
      {:ok, push_navigate(socket, to: ~p"/dashboard")}
    else
      step = if user.onboarding_state in @steps, do: user.onboarding_state, else: "step_1"
      {:ok, push_navigate(socket, to: ~p"/onboarding/#{step}")}
    end
  end

  defp init_socket(socket, user, step) do
    socket
    |> assign(:page_title, "Getting started")
    |> assign(:step, step)
    |> assign(:user, user)
    |> assign(:user_id, user.id)
    |> assign(:env_form, %{"name" => "", "setup_script" => ""})
    |> assign(:env_errors, %{})
    |> assign(:agent_form, %{"name" => "", "system_prompt" => ""})
    |> assign(:agent_errors, %{})
    |> assign(:environments, Environments.list_environments(user.id))
    |> assign(:agents, Agents.list_agents(user.id, []))
    |> assign(:inference_providers, @inference_providers)
    |> assign(:inference_status, InferenceCredentials.status_for_user(user.id))
    |> assign(:inference_messages, %{})
  end

  ## ── Inference (step_1) ──────────────────────────────────────────────────

  @impl true
  def handle_event("save_credential", %{"provider" => provider_str, "value" => value}, socket) do
    provider = String.to_existing_atom(provider_str)
    value = String.trim(value || "")

    if value == "" do
      {:noreply, put_inference_message(socket, provider, :error, "Paste a value before saving.")}
    else
      case Validator.validate(provider, value) do
        :ok ->
          case persist_credential(socket.assigns.user_id, provider, value) do
            {:ok, _} ->
              {:noreply,
               socket
               |> assign(
                 :inference_status,
                 InferenceCredentials.status_for_user(socket.assigns.user_id)
               )
               |> put_inference_message(provider, :info, "Saved and validated.")}

            {:error, reason} ->
              {:noreply,
               put_inference_message(socket, provider, :error, "Could not save: #{inspect(reason)}")}
          end

        {:error, :invalid, %{status: status}} ->
          {:noreply,
           put_inference_message(
             socket,
             provider,
             :error,
             "Provider rejected the credential (HTTP #{status}). Check that you copied the full token."
           )}

        {:error, :timeout} ->
          {:noreply,
           put_inference_message(socket, provider, :error, "Validation timed out. Try again.")}

        {:error, reason} ->
          {:noreply,
           put_inference_message(
             socket,
             provider,
             :error,
             "Could not reach provider (#{inspect(reason)})."
           )}
      end
    end
  end

  def handle_event("continue_from_inference", _params, socket) do
    if InferenceCredentials.has_any_credential?(socket.assigns.user_id) do
      advance(socket, "step_2")
    else
      {:noreply, put_flash(socket, :error, "Set at least one provider to continue.")}
    end
  end

  ## ── Environment (step_2) ────────────────────────────────────────────────

  def handle_event("validate_env", %{"env" => params}, socket) do
    {:noreply, assign(socket, :env_form, params)}
  end

  def handle_event("create_env", %{"env" => params}, socket) do
    attrs = Map.put(params, "user_id", socket.assigns.user_id)

    case Environments.create_environment(attrs) do
      {:ok, _env} -> advance(socket, "step_3")
      {:error, cs} -> {:noreply, assign(socket, :env_errors, changeset_errors(cs))}
    end
  end

  def handle_event("skip_env", _params, socket), do: advance(socket, "step_3")

  ## ── Agent (step_3) ──────────────────────────────────────────────────────

  def handle_event("validate_agent", %{"agent" => params}, socket) do
    {:noreply, assign(socket, :agent_form, params)}
  end

  def handle_event("create_agent", %{"agent" => params}, socket) do
    attrs = Map.put(params, "user_id", socket.assigns.user_id)

    case Agents.create_agent(attrs) do
      {:ok, _agent} -> advance(socket, "step_4")
      {:error, cs} -> {:noreply, assign(socket, :agent_errors, changeset_errors(cs))}
    end
  end

  def handle_event("skip_agent", _params, socket), do: advance(socket, "step_4")

  ## ── Start (step_4) ──────────────────────────────────────────────────────

  def handle_event("start_conversation", _params, socket) do
    {:ok, user} = Accounts.complete_onboarding(socket.assigns.user)
    socket = assign(socket, :user, user)
    {:noreply, push_navigate(socket, to: ~p"/conversations/new")}
  end

  def handle_event("skip_wizard", _params, socket) do
    {:ok, _user} = Accounts.complete_onboarding(socket.assigns.user)
    {:noreply, push_navigate(socket, to: ~p"/dashboard")}
  end

  ## ── Helpers ─────────────────────────────────────────────────────────────

  defp advance(socket, next_step) do
    {:ok, user} = Accounts.advance_onboarding(socket.assigns.user, next_step)
    {:noreply, socket |> assign(:user, user) |> push_navigate(to: ~p"/onboarding/#{next_step}")}
  end

  defp persist_credential(user_id, provider, value) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      InferenceCredentials.put_credential(user_id, dek, provider, value)
    end
  end

  defp put_inference_message(socket, provider, kind, msg) do
    update(socket, :inference_messages, fn map -> Map.put(map, provider, {kind, msg}) end)
  end

  defp changeset_errors(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Map.new(fn {k, [first | _]} -> {to_string(k), first} end)
  end

  ## ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-50 flex flex-col items-center justify-center py-12 px-4">
      <div class="w-full max-w-lg space-y-8">
        <div class="text-center">
          <h1 class="text-2xl font-bold text-zinc-900">Welcome to Fountain</h1>
          <p class="mt-1 text-sm text-zinc-500">Let's get you set up in a few quick steps.</p>
        </div>

        <.progress_bar step={@step} />

        <div class="bg-white rounded-xl shadow border border-zinc-200 p-8">
          <%= case @step do %>
            <% "step_1" -> %>
              <.step_inference
                providers={@inference_providers}
                status={@inference_status}
                messages={@inference_messages}
                any_set?={Enum.any?(@inference_status, fn {_, set?} -> set? end)} />
            <% "step_2" -> %>
              <.step_env env_form={@env_form} env_errors={@env_errors} />
            <% "step_3" -> %>
              <.step_agent agent_form={@agent_form} agent_errors={@agent_errors} environments={@environments} />
            <% "step_4" -> %>
              <.step_start agents={@agents} />
          <% end %>
        </div>

        <div class="text-center">
          <button phx-click="skip_wizard"
            class="text-xs text-zinc-400 hover:text-zinc-600 underline">
            Skip setup and go to dashboard
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :step, :string, required: true

  defp progress_bar(assigns) do
    steps = [
      {"step_1", "1", "Inference"},
      {"step_2", "2", "Environment"},
      {"step_3", "3", "Agent"},
      {"step_4", "4", "Start"}
    ]

    step_index = fn s -> Enum.find_index(steps, fn {id, _, _} -> id == s end) end

    assigns =
      assigns
      |> assign(:steps, steps)
      |> assign(:current_index, step_index.(assigns.step))

    ~H"""
    <div class="flex items-center justify-center gap-2">
      <%= for {{_id, num, label}, i} <- Enum.with_index(@steps) do %>
        <div class="flex items-center gap-2">
          <div class={[
            "w-8 h-8 rounded-full flex items-center justify-center text-sm font-medium border-2",
            if(i <= @current_index,
              do: "bg-zinc-900 border-zinc-900 text-white",
              else: "border-zinc-300 text-zinc-400"
            )
          ]}>
            {num}
          </div>
          <span class={["text-sm", if(i <= @current_index, do: "text-zinc-900 font-medium", else: "text-zinc-400")]}>
            {label}
          </span>
          <div :if={i < length(@steps) - 1} class="w-8 h-px bg-zinc-300 mx-1"></div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :providers, :list, required: true
  attr :status, :map, required: true
  attr :messages, :map, required: true
  attr :any_set?, :boolean, required: true

  defp step_inference(assigns) do
    ~H"""
    <div class="space-y-5">
      <div>
        <h2 class="text-lg font-semibold">Step 1: Connect a provider</h2>
        <p class="mt-1 text-sm text-zinc-500">
          Bring your own inference token. Sandboxes call providers directly with these — Fountain never sees your traffic and you pay providers directly. Set at least one to continue. You can add or change these anytime from Settings.
        </p>
      </div>

      <div class="space-y-3">
        <div :for={{provider, label, source} <- @providers}
             class="rounded-md border border-zinc-200 p-3 space-y-2">
          <div class="flex items-center justify-between">
            <div>
              <span class="text-sm font-medium">{label}</span>
              <span class="text-xs text-zinc-500 ml-2">Get from {source}</span>
            </div>
            <%= if Map.get(@status, provider, false) do %>
              <span class="inline-flex items-center rounded-full bg-emerald-100 text-emerald-800 px-2 py-0.5 text-xs font-medium">Set</span>
            <% else %>
              <span class="inline-flex items-center rounded-full bg-zinc-100 text-zinc-600 px-2 py-0.5 text-xs">Not set</span>
            <% end %>
          </div>

          <form phx-submit="save_credential" class="flex gap-2">
            <input type="hidden" name="provider" value={Atom.to_string(provider)} />
            <input type="password"
                   name="value"
                   placeholder={if Map.get(@status, provider, false), do: "Replace…", else: "Paste token"}
                   autocomplete="off"
                   class="flex-1 rounded-md border border-zinc-300 px-2 py-1.5 text-xs font-mono focus:outline-none focus:ring-2 focus:ring-zinc-900" />
            <button type="submit"
                    class="rounded-md bg-zinc-900 text-white px-3 py-1.5 text-xs font-medium hover:bg-zinc-700">
              Save
            </button>
          </form>

          <%= case Map.get(@messages, provider) do %>
            <% nil -> %>
            <% {:info, msg} -> %>
              <p class="text-xs text-emerald-700">{msg}</p>
            <% {:error, msg} -> %>
              <p class="text-xs text-rose-700">{msg}</p>
          <% end %>
        </div>
      </div>

      <button phx-click="continue_from_inference"
              disabled={!@any_set?}
              class={[
                "w-full rounded-md px-4 py-2 text-sm font-medium",
                if(@any_set?,
                  do: "bg-zinc-900 text-white hover:bg-zinc-700",
                  else: "bg-zinc-200 text-zinc-400 cursor-not-allowed"
                )
              ]}>
        Continue →
      </button>
    </div>
    """
  end

  attr :env_form, :map, required: true
  attr :env_errors, :map, required: true

  defp step_env(assigns) do
    ~H"""
    <div class="space-y-5">
      <div>
        <h2 class="text-lg font-semibold">Step 2: Create an environment</h2>
        <p class="mt-1 text-sm text-zinc-500">
          Environments define the compute context for your agents — packages, env vars, repos.
          You can skip this and set one up later.
        </p>
      </div>

      <form phx-change="validate_env" phx-submit="create_env" class="space-y-4">
        <div class="space-y-1">
          <label class="block text-sm font-medium text-zinc-700">Name</label>
          <input type="text" name="env[name]" value={@env_form["name"]}
            placeholder="my-dev-env" autofocus
            class="w-full rounded-md border border-zinc-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-900"/>
          <p :if={Map.has_key?(@env_errors, "name")} class="text-rose-600 text-xs">
            {Map.get(@env_errors, "name")}
          </p>
        </div>

        <div class="space-y-1">
          <label class="block text-sm font-medium text-zinc-700">Setup script <span class="text-zinc-400 font-normal">(optional)</span></label>
          <textarea name="env[setup_script]" rows="3"
            placeholder="curl -LsSf https://astral.sh/uv/install.sh | sh"
            class="w-full rounded-md border border-zinc-300 px-3 py-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-zinc-900">{@env_form["setup_script"]}</textarea>
        </div>

        <div class="flex gap-2 pt-2">
          <button type="submit"
            class="flex-1 rounded-md bg-zinc-900 text-white px-4 py-2 text-sm font-medium hover:bg-zinc-700">
            Create environment &amp; continue
          </button>
          <button type="button" phx-click="skip_env"
            class="rounded-md border border-zinc-300 px-4 py-2 text-sm text-zinc-600 hover:bg-zinc-50">
            Skip
          </button>
        </div>
      </form>
    </div>
    """
  end

  attr :agent_form, :map, required: true
  attr :agent_errors, :map, required: true
  attr :environments, :list, required: true

  defp step_agent(assigns) do
    ~H"""
    <div class="space-y-5">
      <div>
        <h2 class="text-lg font-semibold">Step 3: Create an agent</h2>
        <p class="mt-1 text-sm text-zinc-500">
          An agent bundles a model, system prompt, and environment into a reusable persona.
        </p>
      </div>

      <form phx-change="validate_agent" phx-submit="create_agent" class="space-y-4">
        <div class="space-y-1">
          <label class="block text-sm font-medium text-zinc-700">Name</label>
          <input type="text" name="agent[name]" value={@agent_form["name"]}
            placeholder="My first agent" autofocus
            class="w-full rounded-md border border-zinc-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-900"/>
          <p :if={Map.has_key?(@agent_errors, "name")} class="text-rose-600 text-xs">
            {Map.get(@agent_errors, "name")}
          </p>
        </div>

        <div class="space-y-1">
          <label class="block text-sm font-medium text-zinc-700">System prompt <span class="text-zinc-400 font-normal">(optional)</span></label>
          <textarea name="agent[system_prompt]" rows="4"
            placeholder="You are a helpful assistant..."
            class="w-full rounded-md border border-zinc-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-900">{@agent_form["system_prompt"]}</textarea>
        </div>

        <div :if={@environments != []} class="space-y-1">
          <label class="block text-sm font-medium text-zinc-700">Environment <span class="text-zinc-400 font-normal">(optional)</span></label>
          <select name="agent[environment_id]"
            class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm">
            <option value="">— none —</option>
            <option :for={e <- @environments} value={e.id}>{e.name}</option>
          </select>
        </div>

        <div class="flex gap-2 pt-2">
          <button type="submit"
            class="flex-1 rounded-md bg-zinc-900 text-white px-4 py-2 text-sm font-medium hover:bg-zinc-700">
            Create agent &amp; continue
          </button>
          <button type="button" phx-click="skip_agent"
            class="rounded-md border border-zinc-300 px-4 py-2 text-sm text-zinc-600 hover:bg-zinc-50">
            Skip
          </button>
        </div>
      </form>
    </div>
    """
  end

  attr :agents, :list, required: true

  defp step_start(assigns) do
    ~H"""
    <div class="space-y-5 text-center">
      <div>
        <div class="text-4xl mb-3">🎉</div>
        <h2 class="text-lg font-semibold">You're all set!</h2>
        <p class="mt-1 text-sm text-zinc-500">
          <%= if @agents != [] do %>
            You have <%= length(@agents) %> agent<%= if length(@agents) > 1, do: "s" %> ready to go.
            Start your first conversation now.
          <% else %>
            Your account is ready. Start a conversation to try it out — you can add agents anytime.
          <% end %>
        </p>
      </div>

      <div class="flex flex-col gap-3 pt-2">
        <button phx-click="start_conversation"
          class="w-full rounded-md bg-zinc-900 text-white px-4 py-2.5 text-sm font-medium hover:bg-zinc-700">
          Start first conversation →
        </button>
        <button phx-click="skip_wizard"
          class="w-full rounded-md border border-zinc-300 px-4 py-2.5 text-sm text-zinc-600 hover:bg-zinc-50">
          Go to dashboard
        </button>
      </div>
    </div>
    """
  end
end
