defmodule FountainWeb.AgentsLive.IndexTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Runtimes.Model

  describe "index" do
    test "renders agent list for authenticated user", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ agent.name
      assert html =~ "+ New agent"
      assert html =~ "Edit"
    end

    test "renders empty state when user has no agents", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "No agents yet"
    end

    test "new agent button uses plain href (not LiveView navigate)", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/agents")

      # Must be a plain href so the browser always performs a real navigation.
      # Regression: navigate= was a no-op in some LiveSocket states (e.g. after
      # visiting a conversation page where JS hooks had been mounted).
      assert has_element?(view, ~s(a[href="/agents/new"]))
      refute has_element?(view, ~s(a[data-phx-link][href="/agents/new"]))
    end

    test "edit button uses plain href (not LiveView navigate)", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/agents")

      assert has_element?(view, ~s(a[href="/agents/#{agent.id}/edit"]))
      refute has_element?(view, ~s(a[data-phx-link][href="/agents/#{agent.id}/edit"]))
    end

    test "redirects unauthenticated user to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/agents")
      assert path =~ "/auth/login"
    end
  end

  describe "new" do
    test "renders new agent form for authenticated user", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/new")

      assert html =~ "New agent"
      assert html =~ "phx-submit"
    end

    test "redirects unauthenticated user to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/agents/new")
      assert path =~ "/auth/login"
    end

    # Onboarding asks for Anthropic only; the first model that needs another
    # provider is where its key is collected.
    test "prompts for the provider's key when the chosen model has none on the account", %{
      conn: conn
    } do
      user = insert_verified_user()
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      {:ok, _} =
        Fountain.InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-ant")

      conn = login_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/agents/new")
      # default model is Anthropic → nothing to ask
      refute html =~ "No OpenAI API key"
      refute html =~ "credential on this account yet"

      html =
        view
        |> element("form[phx-change=validate]")
        |> render_change(%{
          "agent" => %{"name" => "x", "runtime" => "codex", "model" => "openai/gpt-5"}
        })

      assert html =~ "No OpenAI credential on this account yet"
      assert html =~ ~s(value="openai_api_key")

      # back to an Anthropic model: the card goes away
      html =
        view
        |> element("form[phx-change=validate]")
        |> render_change(%{
          "agent" => %{
            "name" => "x",
            "runtime" => "claude",
            "model" => "anthropic/claude-sonnet-5"
          }
        })

      refute html =~ "credential on this account yet"

      # a model from a provider Fountain doesn't know needs nothing
      html =
        view
        |> element("form[phx-change=validate]")
        |> render_change(%{
          "agent" => %{"name" => "x", "runtime" => "opencode", "model" => "ollama/llama3"}
        })

      refute html =~ "credential on this account yet"
    end

    # #554: the model field was a bare text input, so nothing in the UI said
    # what a valid value looked like until the sprite failed at spawn time.
    test "model field offers the curated models for the selected runtime", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/agents/new")

      assert html =~ ~s(list="model-options")

      for model <- Model.suggestions("claude") do
        assert has_element?(view, ~s(datalist#model-options option[value="#{model}"]))
      end

      # Switching runtime re-scopes the list — codex can't reach an
      # anthropic/ model, and the changeset rejects one.
      html = render_change(view, "validate", %{"agent" => %{"runtime" => "codex"}})
      assert html =~ "openai/gpt-5.3-codex"
      refute html =~ "anthropic/claude-opus-5"
    end

    test "an unlisted model id is flagged as pass-through, not as an error", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/agents/new")

      listed =
        render_change(view, "validate", %{
          "agent" => %{"runtime" => "claude", "model" => "anthropic/claude-opus-5"}
        })

      refute listed =~ "passed to the runtime as-is"

      unlisted =
        render_change(view, "validate", %{
          "agent" => %{"runtime" => "claude", "model" => "anthropic/claude-opus-99"}
        })

      assert unlisted =~ "passed to the runtime as-is"

      # A bad provider is a real error, not a pass-through — stay quiet and
      # let the changeset speak on submit.
      bad_provider =
        render_change(view, "validate", %{
          "agent" => %{"runtime" => "opencode", "model" => "anthopic/claude-opus-5"}
        })

      refute bad_provider =~ "passed to the runtime as-is"
    end
  end

  describe "edit" do
    test "renders edit form for existing agent", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      assert html =~ "Edit agent"
      assert html =~ agent.name
    end

    test "redirects unauthenticated user to login", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/agents/#{agent.id}/edit")
      assert path =~ "/auth/login"
    end
  end

  describe "permission policy (#939)" do
    # The form renders a credential card, as its own nested <form>, when the
    # account holds no key for the model's provider. Nested forms truncate the
    # outer one for LiveViewTest, so a submit test needs the key on file.
    defp with_credential(user) do
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      {:ok, _} =
        Fountain.InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-ant-x")

      user
    end

    test "the form shows what answers before the agent runs a tool", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, permission_policy: %{"default" => "ask"})
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      assert html =~ "Before the agent runs a tool"
      assert html =~ "Ask a human"
      # The stored default is the one selected, rather than the field showing
      # allow while the row says otherwise.
      assert html =~ ~r/<option value="ask" selected/
    end

    test "saving stores the default and the per-kind overrides", %{conn: conn} do
      user = with_credential(insert_verified_user())
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")

      view
      |> form("form", %{
        "agent" => %{
          "name" => agent.name,
          "model" => agent.model,
          "runtime" => agent.runtime,
          "permission_default" => "ask",
          "permission_kinds" => %{"execute" => "auto_deny", "read" => ""}
        }
      })
      |> render_submit()

      assert %{"default" => "ask", "execute" => "auto_deny"} =
               Fountain.Agents.get_agent(agent.id, user.id).permission_policy
    end

    test "an untouched form leaves the policy empty rather than writing a default", %{conn: conn} do
      # Every agent predates this field. Saving an unrelated edit must not
      # start writing `%{"default" => "auto_allow"}` into rows that had `%{}`,
      # which would read as a policy someone chose.
      user = with_credential(insert_verified_user())
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")

      view
      |> form("form", %{
        "agent" => %{
          "name" => "renamed",
          "model" => agent.model,
          "runtime" => agent.runtime
        }
      })
      |> render_submit()

      assert Fountain.Agents.get_agent(agent.id, user.id).permission_policy == %{}
    end

    test "a runtime that never asks says so instead of offering the choice", %{conn: conn} do
      # opencode decides permission in its own server and sends no request
      # (#959), so a policy here would display a restriction nothing enforces.
      user = insert_verified_user()

      agent =
        insert_agent(user_id: user.id, runtime: "opencode", model: "anthropic/claude-sonnet-5")

      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      assert html =~ "decides this inside its own server"
      assert html =~ "disabled"
    end
  end
end

defmodule FountainWeb.AgentsLive.NetworkPolicyNoteTest do
  # async: false because it flips `:runners_enabled`, which is application-wide
  # config the rest of the suite reads to decide which providers are enabled.
  # `:runner` is the only adapter in tree without `:network_policy`, so it is
  # the only pairing that can express this.
  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    previous = Application.get_env(:fountain, :runners_enabled)
    Application.put_env(:fountain, :runners_enabled, true)
    on_exit(fn -> Application.put_env(:fountain, :runners_enabled, previous) end)
    :ok
  end

  describe "network policy the backend cannot enforce (#935)" do
    # The provider is per agent (ADR 0018) and the egress policy is per
    # environment, so the agent form is the only console page where both are
    # known. Without this the pairing is discovered by a conversation dying
    # mid-provision.
    test "warns when a limited environment is paired with a backend that has no policy", %{
      conn: conn
    } do
      user = insert_verified_user()
      env = insert_env(user_id: user.id, networking_type: "limited", networking_config: %{})

      agent =
        insert_agent(user_id: user.id, environment_id: env.id, sandbox_provider: "runner")

      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      assert html =~ "cannot hold a limited environment"
      assert html =~ "runner"
    end

    test "no warning when the backend advertises a network policy", %{conn: conn} do
      user = insert_verified_user()
      env = insert_env(user_id: user.id, networking_type: "limited", networking_config: %{})

      # No pin, so the agent runs on the instance default. That is sprites,
      # which advertises `:network_policy`, as do e2b and daytona.
      agent = insert_agent(user_id: user.id, environment_id: env.id)

      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      refute html =~ "cannot hold a limited environment"
    end

    test "no warning when the environment is unrestricted", %{conn: conn} do
      user = insert_verified_user()
      env = insert_env(user_id: user.id, networking_type: "unrestricted")

      agent =
        insert_agent(user_id: user.id, environment_id: env.id, sandbox_provider: "runner")

      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      refute html =~ "cannot hold a limited environment"
    end
  end
end
