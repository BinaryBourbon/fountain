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

  test "the marketing page and legal pages name the brand; the CLI stays fountain", %{conn: conn} do
    home = conn |> get(~p"/") |> html_response(200)
    assert home =~ "Every agent gets a brief, a budget, and a boundary."
    assert home =~ "Managoat scrubs them from every line of output"
    assert home =~ ">fountain</code> CLI"
    assert home =~ "© 2026 Managoat."
    assert home =~ ~s(data-role="hosted-brand")
    assert home =~ "Managoat is the hosted Fountain. The engine is open source"
    assert home =~ "It runs Fountain, which is open source."

    for path <- [~p"/terms", ~p"/privacy"] do
      html = conn |> get(path) |> html_response(200)
      assert html =~ "Managoat"
      refute html =~ "the Fountain service"
      refute html =~ "Fountain is operated by"
      refute html =~ "Fountain lets you"
    end
  end

  test "without the brand the marketing site credits nobody", %{conn: conn} do
    Application.delete_env(:fountain, :product_name)
    home = conn |> get(~p"/") |> html_response(200)
    assert home =~ "© 2026 Fountain."
    refute home =~ "It runs Fountain, which is open source."
  end

  test "without the brand the docs show no note", %{conn: conn} do
    Application.delete_env(:fountain, :product_name)
    html = conn |> get(~p"/docs") |> html_response(200)
    refute html =~ ~s(data-role="brand-note")
    assert html =~ ~r/>\s*Fountain\s*<\/span>/
  end

  describe "BRAND_ASSETS_URL" do
    setup do
      previous = Application.get_env(:fountain, :brand_assets_url)
      Application.put_env(:fountain, :brand_assets_url, "https://cdn.example.com/brand")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:fountain, :brand_assets_url, previous),
          else: Application.delete_env(:fountain, :brand_assets_url)
      end)

      :ok
    end

    test "the chrome, the favicons and the card come from the bundle", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)
      assert html =~ ~s(src="https://cdn.example.com/brand/app-icon.png")
      assert html =~ ~s(href="https://cdn.example.com/brand/favicon.ico")
      assert html =~ ~s(href="https://cdn.example.com/brand/favicon-32x32.png")
      assert html =~ ~s(href="https://cdn.example.com/brand/favicon-16x16.png")
      assert html =~ ~s(href="https://cdn.example.com/brand/apple-touch-icon.png")

      assert html =~
               ~s(<meta property="og:image" content="https://cdn.example.com/brand/og-card.png")

      assert html =~
               ~s(<meta name="twitter:image" content="https://cdn.example.com/brand/og-card.png")

      refute html =~ "/images/app-icon.png"
      refute html =~ "/images/og-card.png"
    end

    test "the console header uses the bundle too", %{conn: conn} do
      user = Fountain.Factory.insert_verified_user()
      html = conn |> login_user(user) |> get(~p"/dashboard") |> html_response(200)
      assert html =~ ~s(src="https://cdn.example.com/brand/app-icon.png")
    end

    test "the CSP admits the bundle's origin on img-src, once, and nowhere else", %{conn: conn} do
      [csp] = conn |> get(~p"/") |> get_resp_header("content-security-policy")
      assert csp =~ "img-src 'self' data: https://cdn.example.com"
      refute csp =~ "script-src 'self' 'unsafe-inline' https://cdn.example.com"
      assert length(String.split(csp, "https://cdn.example.com")) == 2
    end
  end

  test "without a bundle the CSP is untouched", %{conn: conn} do
    Application.delete_env(:fountain, :brand_assets_url)
    [csp] = conn |> get(~p"/") |> get_resp_header("content-security-policy")
    assert csp =~ "img-src 'self' data:;"
  end
end
