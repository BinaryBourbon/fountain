defmodule FountainWeb.BrandChromeTest do
  use FountainWeb.ConnCase, async: false

  # PRODUCT_NAME is a per-deployment brand for the chrome only: the manual
  # keeps saying Fountain (the engine) and explains the split once per page.
  setup do
    previous = Application.get_env(:fountain, :product_name)
    Application.put_env(:fountain, :product_name, "Managoat")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :product_name, previous),
        else: Application.delete_env(:fountain, :product_name)
    end)

    :ok
  end

  test "the docs header carries the brand and each page explains the split", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)
    assert html =~ ~s(<title>Docs · )
    assert html =~ ~r/>\s*Managoat\s*<\/span>/
    assert html =~ ~s(data-role="brand-note")
    assert html =~ ~r/Managoat<\/span>\s*is the hosted Fountain/
    # The page body is the engine's manual, untouched.
    assert html =~ "Fountain runs an agent on a cloud sandbox"
  end

  test "the sign-in page and default title use the brand", %{conn: conn} do
    html = conn |> get(~p"/auth/login") |> html_response(200)
    assert html =~ "Sign in to Managoat"
  end

  test "email subjects use the brand" do
    import Swoosh.TestAssertions
    user = Fountain.Factory.insert_verified_user()
    {:ok, _} = Fountain.Emails.UserEmails.deliver_verification_email(user, "tok")
    assert_email_sent(subject: "Verify your Managoat account")
  end

  test "without the brand the docs show no note", %{conn: conn} do
    Application.delete_env(:fountain, :product_name)
    html = conn |> get(~p"/docs") |> html_response(200)
    refute html =~ ~s(data-role="brand-note")
    assert html =~ ~r/>\s*Fountain\s*<\/span>/
  end
end
