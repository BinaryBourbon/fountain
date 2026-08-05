defmodule Fountain.ReleasePinTest do
  # The self-host quick start pins a release image in four places. Those pins
  # sat at v0.3.0 through two releases, handing newcomers an image from before
  # the in-app first-login flow (#478), where EMAIL_DELIVERY=none dead-ends
  # signup. release-bump.yml now bumps the pins inside the release commit;
  # since that commit is [skip ci], this test is the net that catches a pin
  # the workflow missed — on the next PR, not two releases later.
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  @pins [
    {"docker-compose.yml", ~r/fountain:\$\{FOUNTAIN_IMAGE_TAG:-(v[\d.]+)\}/},
    {".env.compose.example", ~r/^FOUNTAIN_IMAGE_TAG=(v[\d.]+)$/m},
    {"deploy/k8s/kustomization.yaml", ~r/newTag: (v[\d.]+)/},
    {"deploy/k8s/deployment.yaml", ~r/image: ghcr\.io\/binarybourbon\/fountain:(v[\d.]+)/}
  ]

  test "self-host image pins match the released version" do
    expected = "v" <> to_string(Application.spec(:fountain, :vsn))

    for {file, regex} <- @pins do
      pinned =
        case Regex.run(regex, File.read!(Path.join(@root, file))) do
          [_, tag] -> tag
          nil -> flunk("#{file}: image pin not found (pattern #{inspect(regex)})")
        end

      assert pinned == expected,
             "#{file} pins #{pinned} but the released version is #{expected}; " <>
               "release-bump.yml should have bumped it in the release commit"
    end
  end
end
