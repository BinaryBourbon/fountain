defmodule Fountain.Factory do
  @moduledoc """
  Test factories for AoD. Lean and explicit — no factory_bot magic.

  Each `*_attrs/1` returns a map suitable for the corresponding context's
  create function. `insert_*/1` writes the row through the regular
  changeset so tests have realistic data, but factories accept *both*
  keyword lists and atom-keyed maps for ergonomics in tests.
  """

  alias Fountain.Repo
  alias Fountain.Conversations.{Conversation, LogEvent, Sandbox, Turn}

  defp uniq, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()

  # ── users ─────────────────────────────────────────────────────────────────

  def user_attrs(overrides \\ %{}) do
    Map.merge(
      %{"email" => "user#{uniq()}@example.com", "password" => "password123"},
      to_string_map(overrides)
    )
  end

  def insert_user(overrides \\ %{}) do
    {:ok, user} = Fountain.Accounts.register_user(user_attrs(overrides))
    user
  end

  def insert_verified_user(overrides \\ %{}) do
    user = insert_user(overrides)
    {:ok, verified} = Fountain.Accounts.verify_email(user)
    verified
  end

  def insert_api_key(user, name \\ nil) do
    name = name || "key-#{uniq()}"
    {:ok, {key_record, raw_key}} = Fountain.Accounts.create_api_key(user.id, name)
    {key_record, raw_key}
  end

  # ── environments ──────────────────────────────────────────────────────────

  def env_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "env-#{uniq()}",
        "packages" => %{},
        "env_vars" => %{},
        "setup_script" => "",
        "networking_type" => "unrestricted",
        "networking_config" => %{},
        "repositories" => []
      },
      to_string_map(overrides)
    )
  end

  def insert_env(overrides \\ %{}) do
    {:ok, env} = Fountain.Environments.create_environment(env_attrs(overrides))
    env
  end

  def insert_secret(env, overrides \\ %{}) do
    attrs =
      %{"key" => "TEST_KEY_#{uniq()}", "value" => "test-value-#{uniq()}"}
      |> Map.merge(to_string_map(overrides))

    {:ok, secret} = Fountain.Environments.upsert_secret(env, attrs)
    secret
  end

  # ── vaults ────────────────────────────────────────────────────────────────

  def vault_attrs(overrides \\ %{}) do
    Map.merge(
      %{"name" => "vault-#{uniq()}", "description" => ""},
      to_string_map(overrides)
    )
  end

  def insert_vault(overrides \\ %{}) do
    {:ok, vault} = Fountain.Vaults.create_vault(vault_attrs(overrides))
    vault
  end

  def insert_vault_secret(vault, overrides \\ %{}) do
    attrs =
      %{"key" => "TEST_KEY_#{uniq()}", "value" => "test-value-#{uniq()}"}
      |> Map.merge(to_string_map(overrides))

    {:ok, secret} = Fountain.Vaults.upsert_secret(vault, attrs)
    secret
  end

  # ── agents ────────────────────────────────────────────────────────────────

  def agent_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "agent-#{uniq()}",
        "model" => "anthropic/claude-sonnet-4-6",
        "runtime" => "claude",
        "skills" => [],
        "mcp_servers" => %{},
        "metadata" => %{}
      },
      to_string_map(overrides)
    )
  end

  def insert_agent(overrides \\ %{}) do
    {:ok, agent} = Fountain.Agents.create_agent(agent_attrs(overrides))
    agent
  end

  # ── conversations / sandboxes / turns ─────────────────────────────────────

  def insert_sandbox(overrides \\ %{}) do
    attrs =
      %{sprite_name: "test-sprite-#{uniq()}", status: "pending"}
      |> Map.merge(to_atom_map(overrides))

    %Sandbox{}
    |> Sandbox.changeset(attrs)
    |> Repo.insert!()
  end

  def insert_conversation(overrides \\ %{}) do
    overrides_map = to_atom_map(overrides)
    sandbox = Map.get(overrides_map, :sandbox) || insert_sandbox()
    agent = Map.get(overrides_map, :agent)

    base = %{
      sandbox_id: sandbox.id,
      agent_id: agent && agent.id,
      runtime: "claude",
      status: "pending"
    }

    attrs = Map.merge(base, Map.drop(overrides_map, [:sandbox, :agent]))

    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert!()
    |> Repo.preload([:sandbox, :agent])
  end

  def insert_turn(conv, overrides \\ %{}) do
    attrs =
      %{
        conversation_id: conv.id,
        turn_number: Fountain.Conversations.next_turn_number(conv.id),
        prompt: "test prompt",
        status: "pending"
      }
      |> Map.merge(to_atom_map(overrides))

    %Turn{}
    |> Turn.changeset(attrs)
    |> Repo.insert!()
  end

  def insert_log_event(conv, overrides \\ %{}) do
    attrs =
      %{
        conversation_id: conv.id,
        kind: "output",
        stream: "stdout",
        data: "test data",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
      |> Map.merge(to_atom_map(overrides))

    %LogEvent{}
    |> LogEvent.changeset(attrs)
    |> Repo.insert!()
  end

  # ── key helpers ───────────────────────────────────────────────────────────

  # Always return a map keyed by strings.
  def to_string_map(input) when is_list(input), do: input |> Map.new() |> to_string_map()

  def to_string_map(input) when is_map(input) do
    Map.new(input, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # Always return a map keyed by atoms (where atoms exist).
  def to_atom_map(input) when is_list(input), do: input |> Map.new() |> to_atom_map()

  def to_atom_map(input) when is_map(input) do
    Map.new(input, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {safe_to_existing_atom(k, k), v}
    end)
  end

  defp safe_to_existing_atom(s, fallback) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> fallback
  end
end
