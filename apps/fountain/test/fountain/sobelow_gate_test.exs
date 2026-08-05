defmodule Fountain.SobelowGateTest do
  use ExUnit.Case, async: true

  # Regression test for #414: the sobelow gate ran with exit: "high", but
  # sobelow rates non-controller raw/1 (this repo's entire XSS surface) as
  # :low and the interpolated-variable case as :medium — so the gate could
  # not fail on the exact class it exists for. #311 fixed the scan's
  # working directory and never revisited the threshold.
  #
  # The gate's teeth were demonstrated when this landed: with any one
  # sobelow_skip marker removed, `mix sobelow --config` exits 1.
  test "the sobelow config fails on low-confidence findings and honours named skips" do
    {config, _} = Code.eval_file(".sobelow-conf")

    assert config[:exit] == "low",
           ".sobelow-conf exit threshold was raised above \"low\" — sobelow rates " <>
             "non-controller raw/1 XSS as :low, so anything higher makes the gate " <>
             "unable to fail on this repo's XSS class (#414)"

    assert config[:skip] == true,
           ".sobelow-conf skip: true is what makes the per-site sobelow_skip " <>
             "markers (the named-exception list) work; without it every accepted " <>
             "finding fails the build"

    assert config[:ignore] == [] and config[:ignore_files] == [],
           "blanket ignores defeat the named-exception discipline — accept a " <>
             "finding with a justified sobelow_skip marker at the call site instead"
  end

  # Since #472 the billing/email web modules live in ee/lib, outside sobelow's
  # reach from apps/fountain. scripts/sobelow.sh scans a merged core+ee tree;
  # a revert to bare `mix sobelow --config` would drop ee from the scan and
  # still exit 0 — the same invisible-gate failure mode as #311.
  test "the sobelow gate runs through scripts/sobelow.sh so ee/lib is scanned" do
    import Bitwise

    root = Path.expand("../../../..", __DIR__)
    script = Path.join(root, "scripts/sobelow.sh")

    assert File.exists?(script),
           "scripts/sobelow.sh is missing — it is what puts ee/lib inside the " <>
             "sobelow scan (decisions/0010)"

    assert (File.stat!(script).mode &&& 0o111) != 0,
           "scripts/sobelow.sh is not executable"

    assert File.read!(script) =~ "ee/lib",
           "scripts/sobelow.sh no longer overlays ee/lib into the scan tree"

    for {caller, path} <- [
          {"CI", Path.join(root, ".github/workflows/ci.yml")},
          {"mix precommit", Path.join(root, "mix.exs")}
        ] do
      assert File.read!(path) =~ "scripts/sobelow.sh",
             "#{caller} no longer runs sobelow through scripts/sobelow.sh — " <>
               "ee/lib web modules would silently leave the scan (decisions/0010)"
    end
  end
end
