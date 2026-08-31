defmodule FountainWeb.PaperSkinTest do
  @moduledoc """
  The paper skin is a second set of values for tokens declared somewhere else,
  and it hangs off attributes written in a template it does not live next to.
  Both of those can come undone without anything failing to render.

  A misspelled token name in `paper.css` is not an error: it declares a custom
  property nothing reads, the page keeps the classic value, and the skin is
  simply wrong in one place. A `data-role` dropped from the homepage is not an
  error either: the rule that hangs off it stops matching and the section
  quietly rejoins the ground. This file is the wiring check for both.
  """
  use FountainWeb.ConnCase, async: true

  @paper Path.expand("../../priv/static/assets/paper.css", __DIR__)
  @tokens Path.expand("../../priv/static/assets/tokens.css", __DIR__)
  @layout Path.expand("../../lib/fountain_web/components/layouts/root.html.heex", __DIR__)
  @templates Path.expand("../../lib/fountain_web/controllers/marketing_html", __DIR__)
  @home Path.expand(
          "../../lib/fountain_web/controllers/marketing_html/home.html.heex",
          __DIR__
        )

  @external_resource @paper
  @external_resource @tokens
  @external_resource @home

  defp declared(css), do: Regex.scan(~r/(--[\w-]+)\s*:/, css) |> Enum.map(&Enum.at(&1, 1))

  describe "the stylesheet" do
    test "is served at the versioned path the layout would link" do
      assert File.exists?(@paper)

      expected =
        :sha256
        |> :crypto.hash(File.read!(@paper))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 8)

      assert FountainWeb.StaticVersion.paper_version() == expected,
             "the compiled hash is stale against priv/static/assets/paper.css"

      assert FountainWeb.StaticVersion.paper_css() == "/assets/paper.css?v=" <> expected
    end

    test "redefines only tokens that tokens.css declares" do
      # The skin's own variables are namespaced `--paper-*`. Everything else it
      # sets has to be a name the templates already read through Tailwind, or
      # it is a declaration with no reader.
      known = @tokens |> File.read!() |> declared() |> MapSet.new()

      unknown =
        @paper
        |> File.read!()
        |> declared()
        |> Enum.reject(&(String.starts_with?(&1, "--paper-") or MapSet.member?(known, &1)))
        |> Enum.uniq()

      assert unknown == [],
             "paper.css sets #{inspect(unknown)}, which tokens.css does not declare"
    end

    test "the hooks it styles are still in the homepage" do
      home = File.read!(@home)

      for role <- ~w(hero figure) do
        assert home =~ ~s(data-role="#{role}"),
               ~s(paper.css styles [data-role="#{role}"] and the homepage no longer carries it)
      end
    end

    test "every glyph a marketing page renders carries the hook that hides it" do
      # The app glyphs are colour emoji and the skin drops them. A card added
      # without the hook is one sticker on a page that has no others, and it
      # renders correctly, so nothing else would catch it.
      for file <- Path.wildcard(Path.join(@templates, "*.heex")) do
        source = File.read!(file)
        glyphs = source |> String.split("{app.glyph}") |> length() |> Kernel.-(1)
        hooks = source |> String.split(~s(data-role="glyph")) |> length() |> Kernel.-(1)

        assert glyphs == hooks,
               "#{Path.basename(file)} renders #{glyphs} glyphs and carries #{hooks} hooks"
      end
    end

    test "the mark is a brand file, so no brand's pixels live in this repository" do
      # The goat is Managoat's, not the engine's: brand images are served from
      # `BRAND_ASSETS_URL` so that changing one is not an image rebuild. The
      # skin therefore names no drawing of its own — the layout resolves
      # `mark-mono.png` through the bundle and hands the URL to the property.
      layout = File.read!(@layout)
      css = File.read!(@paper)

      assert layout =~ ~S|Fountain.Brand.asset("mark-mono.png")|,
             "the layout no longer resolves the mark, so the skin falls back to the engine's"

      assert "mark-mono.png" in Fountain.Brand.assets()
      assert css =~ "--paper-mark"
    end

    test "declares a dark value for every surface it lightens" do
      # The skin is a light page, and the tokens it sets are read on a dark
      # one too. A surface given a paper value here and no value under
      # `[data-theme="dark"]` is a cream slab on a near-black page.
      css = File.read!(@paper)
      [light, dark] = String.split(css, ~s([data-theme="dark"][data-skin="paper"] {), parts: 2)

      surfaces =
        light
        |> declared()
        |> Enum.filter(&String.starts_with?(&1, "--color-"))
        |> Enum.uniq()

      missing = Enum.reject(surfaces, &String.contains?(dark, &1 <> ":"))

      assert missing == [],
             "#{inspect(missing)} has a paper value and no dark one"
    end
  end

  # `config/test.exs` pins `:marketing_site`, so these are the pitch here.
  @marketing ~w(
    / /launch /integrations /built-with /self-hosted /faq /code-review-bot
    /case-studies/self-healing-infrastructure /terms /privacy
  )

  describe "the marketing pages" do
    test "every one of them wears the skin and links its stylesheet", %{conn: conn} do
      for path <- @marketing do
        html = conn |> get(path) |> html_response(200)

        assert html =~ ~s(data-skin="paper"), "#{path} is not wearing the skin"
        assert html =~ FountainWeb.StaticVersion.paper_css(), "#{path} links no stylesheet"
      end
    end

    test "?skin=classic is the way back to the blue page", %{conn: conn} do
      html = conn |> get(~p"/?skin=classic") |> html_response(200)

      refute html =~ ~s(data-skin=)
      refute html =~ "/assets/paper.css"
    end

    test "an unknown skin is the paper one, because this is a look", %{conn: conn} do
      html = conn |> get(~p"/?skin=marble") |> html_response(200)

      assert html =~ ~s(data-skin="paper")
    end

    test "the OSS diagram uses the same displayed brand mark as the chrome", %{conn: conn} do
      html = conn |> get(~p"/oss-launch") |> html_response(200)

      assert length(Regex.scan(~r/data-role="brand-mark"/, html)) == 3
      assert File.read!(@paper) =~ ~s(img[data-role="brand-mark"])
    end
  end

  describe "everything that is not a marketing page" do
    # The manual shares its router scope with the pages above, which is why the
    # skin is a plug on the marketing controller rather than on that scope.
    test "the manual keeps the console's tokens", %{conn: conn} do
      html = conn |> get("/docs") |> html_response(200)

      refute html =~ "/assets/paper.css"
      refute html =~ ~s(data-skin=)
    end

    test "so does the app", %{conn: conn} do
      html = conn |> get("/auth/login") |> html_response(200)

      refute html =~ "/assets/paper.css"
    end
  end
end
