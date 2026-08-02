defmodule FountainWeb.ExportControllerTest do
  @moduledoc """
  The download endpoint for account data exports (#288).

  Wrong tenant, missing id, pending, failed and expired are all the same 404
  on purpose — the response must not reveal whether another tenant's artifact
  exists.
  """

  use FountainWeb.ConnCase, async: true
  use Oban.Testing, repo: Fountain.Repo

  import Ecto.Query

  alias Fountain.Audit
  alias Fountain.Exports
  alias Fountain.Exports.Export
  alias Fountain.Repo
  alias Fountain.Workers.AccountExport

  defp completed_export(user) do
    {:ok, export} = Exports.request_export(user)
    :ok = perform_job(AccountExport, %{export_id: export.id, user_id: user.id})
    Repo.get!(Export, export.id)
  end

  test "the owner downloads a plain JSON file", %{conn: conn} do
    user = insert_verified_user()
    insert_agent(user_id: user.id, name: "download-agent")
    export = completed_export(user)

    conn = get(login_user(conn, user), ~p"/account/exports/#{export.id}/download")

    assert conn.status == 200
    assert get_resp_header(conn, "content-encoding") == ["gzip"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~s(attachment; filename="fountain-export-)

    doc = conn.resp_body |> :zlib.gunzip() |> Jason.decode!()
    assert doc["account"]["email"] == user.email
    assert [%{"name" => "download-agent"}] = doc["agents"]
  end

  test "the download is audit-recorded", %{conn: conn} do
    user = insert_verified_user()
    export = completed_export(user)

    get(login_user(conn, user), ~p"/account/exports/#{export.id}/download")

    actions = user.id |> Audit.list_recent_for_user(10) |> Enum.map(& &1.action)
    assert "account.export_downloaded" in actions
  end

  test "another tenant gets 404 for the same id", %{conn: conn} do
    owner = insert_verified_user()
    export = completed_export(owner)

    other = insert_verified_user()
    conn = get(login_user(conn, other), ~p"/account/exports/#{export.id}/download")

    assert conn.status == 404
    assert conn.resp_body == ""
  end

  test "an expired export gets 404 for its owner", %{conn: conn} do
    user = insert_verified_user()
    export = completed_export(user)

    {1, _} =
      Repo.update_all(
        from(e in Export, where: e.id == ^export.id),
        set: [expires_at: DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)]
      )

    conn = get(login_user(conn, user), ~p"/account/exports/#{export.id}/download")
    assert conn.status == 404
  end

  test "a pending export gets 404", %{conn: conn} do
    user = insert_verified_user()
    {:ok, export} = Exports.request_export(user)

    conn = get(login_user(conn, user), ~p"/account/exports/#{export.id}/download")
    assert conn.status == 404
  end

  test "unauthenticated requests are redirected to login", %{conn: conn} do
    user = insert_verified_user()
    export = completed_export(user)

    conn = get(conn, ~p"/account/exports/#{export.id}/download")
    assert redirected_to(conn) =~ "/auth/login"
  end
end
