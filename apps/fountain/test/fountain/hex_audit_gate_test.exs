defmodule Fountain.HexAuditGateTest do
  use ExUnit.Case, async: true

  @advisory_failure "Found packages with security advisories"
  @retirement_failure "Found retired packages"

  test "an advisory fails the gate" do
    {output, status} = run_gate("Advisories:\nfoo 1.0.0\n#{@advisory_failure}\n", 1)

    assert status == 1
    assert output =~ @advisory_failure
  end

  test "a retirement remains visible but does not fail the gate" do
    {output, status} = run_gate("Retired:\nearmark 1.4.48\n#{@retirement_failure}\n", 1)

    assert status == 0
    assert output =~ @retirement_failure
    assert output =~ "Retired dependencies are reported above but do not block CI."
  end

  test "an advisory still fails when a retirement is also present" do
    output =
      "\e[1m#{@retirement_failure}\e[0m\n" <>
        "\e[31m#{@advisory_failure}\e[0m\n"

    {_output, status} = run_gate(output, 1)

    assert status == 1
  end

  test "a clean or fully acknowledged audit passes" do
    {_output, status} = run_gate("Ignored advisories:\nEEF-CVE-2026-43969\n", 0)

    assert status == 0
  end

  test "an inconclusive audit error fails closed" do
    {output, status} = run_gate("registry request failed\n", 2)

    assert status == 2
    assert output =~ "hex.audit failed without a finding summary; failing closed."
  end

  defp run_gate(output, exit_status) do
    root = Path.expand("../../../..", __DIR__)
    script = Path.join(root, "scripts/hex-audit-gate.exs")

    fake_bin = Fountain.TmpDir.mkdir!("hex-audit-gate")
    fake_mix = Path.join(fake_bin, "mix")

    File.write!(fake_mix, """
    #!/bin/sh
    printf '%s' "$HEX_AUDIT_FIXTURE"
    exit "$HEX_AUDIT_FIXTURE_STATUS"
    """)

    File.chmod!(fake_mix, 0o755)

    System.cmd("elixir", [script],
      env: [
        {"PATH", fake_bin <> ":" <> System.fetch_env!("PATH")},
        {"HEX_AUDIT_FIXTURE", output},
        {"HEX_AUDIT_FIXTURE_STATUS", Integer.to_string(exit_status)}
      ],
      stderr_to_stdout: true
    )
  end
end
