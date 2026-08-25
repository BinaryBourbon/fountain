# async: false — these tests mutate the global :legal / :credits_enabled app
# env, which concurrent tests (marketing pages, billing gate) also read.
defmodule FountainWeb.MarketingLegalUnpublishedTest do
  use FountainWeb.ConnCase, async: false

  setup do
    legal = Application.get_env(:fountain, :legal)
    billing = Application.get_env(:fountain, :credits_enabled)

    on_exit(fn ->
      Application.put_env(:fountain, :legal, legal)
      Application.put_env(:fountain, :credits_enabled, billing)
    end)

    :ok
  end

  describe "legal identity unset, billing disabled (self-host default)" do
    setup do
      Application.put_env(:fountain, :legal, nil)
      Application.put_env(:fountain, :credits_enabled, false)
      :ok
    end

    test "/terms renders a neutral 404 instead of placeholders", %{conn: conn} do
      body = conn |> get(~p"/terms") |> html_response(404)
      assert body =~ "No published terms"
      refute body =~ "{{"
      refute body =~ "Terms of Service"
    end

    test "/privacy renders a neutral 404 instead of placeholders", %{conn: conn} do
      body = conn |> get(~p"/privacy") |> html_response(404)
      assert body =~ "No published terms"
      refute body =~ "{{"
      refute body =~ "Privacy Policy"
    end

    test "registration form hides the terms/privacy agreement line", %{conn: conn} do
      body = conn |> get(~p"/auth/register") |> html_response(200)
      refute body =~ ~p"/terms"
      refute body =~ ~p"/privacy"
      refute body =~ "By signing up you agree"
    end

    test "marketing footer hides the terms/privacy links", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      refute body =~ ~p"/terms"
      refute body =~ ~p"/privacy"
    end
  end

  describe "legal identity unset, billing enabled" do
    setup do
      Application.put_env(:fountain, :legal, nil)
      Application.put_env(:fountain, :credits_enabled, true)
      :ok
    end

    # An instance charging money must not lose its terms pages — they stay up
    # with #506's deliberately-loud placeholders until the operator sets the
    # LEGAL_* vars.
    test "/terms stays up with loud placeholders", %{conn: conn} do
      body = conn |> get(~p"/terms") |> html_response(200)
      assert body =~ "Terms of Service"
      assert body =~ "{{COMPANY_LEGAL_NAME}}"
    end

    test "/privacy stays up with loud placeholders", %{conn: conn} do
      body = conn |> get(~p"/privacy") |> html_response(200)
      assert body =~ "Privacy Policy"
      assert body =~ "{{COMPANY_LEGAL_NAME}}"
    end

    test "links remain visible on signup and the footer", %{conn: conn} do
      signup = conn |> get(~p"/auth/register") |> html_response(200)
      assert signup =~ ~p"/terms"

      footer = conn |> get(~p"/") |> html_response(200)
      assert footer =~ ~p"/terms"
      assert footer =~ ~p"/privacy"
    end
  end
end
