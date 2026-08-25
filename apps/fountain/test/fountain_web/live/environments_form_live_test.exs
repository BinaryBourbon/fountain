defmodule FountainWeb.EnvironmentsFormLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.{Crypto, Environments}

  setup %{conn: conn} do
    user = insert_verified_user()
    {:ok, conn: login_user(conn, user), user: user}
  end

  defp put_secret(user, env) do
    {:ok, dek} = Crypto.load_tenant_key(user.id)

    {:ok, _} =
      Environments.upsert_secret(env, %{"key" => "GITHUB_TOKEN", "value" => "ghp_x"}, dek)

    env
  end

  test "renders env whose package value is not a list (node: \"24\")", %{conn: conn, user: user} do
    env = insert_env(user_id: user.id)

    {:ok, env} =
      Environments.update_environment(env, %{"packages" => %{"apt" => ["jq"], "node" => "24"}})

    {:ok, _v, html} = live(conn, ~p"/environments/#{env.id}/edit")
    assert html =~ ~s(name="env[packages][node]")
  end

  test "renders fountain-dev exact shape", %{conn: conn, user: user} do
    env = insert_env(user_id: user.id)

    {:ok, env} =
      Environments.update_environment(env, %{
        "packages" => %{
          "apt" => [
            "jq",
            "ripgrep",
            "make",
            "erlang-nox",
            "elixir",
            "postgresql",
            "postgresql-contrib",
            "inotify-tools",
            "golang-go"
          ]
        },
        "env_vars" => %{
          "MIX_ENV" => "dev",
          "DATABASE_URL" => "postgres://postgres:postgres@localhost:5432/fountain_dev",
          "MASTER_SECRETS_KEY" => "dev-only"
        },
        "repositories" => [
          %{
            "url" => "https://github.com/BinaryBourbon/fountain",
            "mount_path" => "/workspace/fountain",
            "secret_key" => "GITHUB_TOKEN"
          }
        ]
      })

    put_secret(user, env)
    {:ok, _v, html} = live(conn, ~p"/environments/#{env.id}/edit")
    assert html =~ "GITHUB_TOKEN"
  end

  test "renders fountain-contributor exact shape", %{conn: conn, user: user} do
    env = insert_env(user_id: user.id)

    {:ok, env} =
      Environments.update_environment(env, %{
        "packages" => %{
          "apt" => [
            "build-essential",
            "autoconf",
            "m4",
            "libncurses-dev",
            "libssl-dev",
            "unzip",
            "jq",
            "ripgrep",
            "postgresql",
            "postgresql-contrib",
            "python3"
          ]
        },
        "env_vars" => %{
          "DATABASE_URL" => "postgres://postgres:postgres@localhost:5432/fountain_dev",
          "LANG" => "C.UTF-8"
        },
        "repositories" => [
          %{
            "url" => "https://github.com/BinaryBourbon/fountain",
            "mount_path" => "/workspace/fountain",
            "secret_key" => "GITHUB_TOKEN"
          }
        ]
      })

    put_secret(user, env)
    {:ok, _v, _html} = live(conn, ~p"/environments/#{env.id}/edit")
  end
end
