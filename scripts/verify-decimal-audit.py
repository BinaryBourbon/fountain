# Verify the temporary acknowledgment against the public registry.
# When the feed is corrected, the changed-checksum case should stop failing;
# remove the acknowledgment and this historical reproducer then.
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
output = (
    Path(sys.argv[1])
    if len(sys.argv) > 1
    else Path(tempfile.mkdtemp(prefix="decimal-audit-results-"))
)
output = output.resolve()
output.mkdir(parents=True, exist_ok=True)
probe = Path(tempfile.mkdtemp(prefix="project-", dir=output))
shutil.copy(root / "config/hex_advisories.exs", probe / "hex_advisories.exs")
shutil.copy(root / ".tool-versions", probe / ".tool-versions")
(probe / "mix.exs").write_text("""Code.require_file("hex_advisories.exs", __DIR__)
defmodule DecimalAuditProbe.MixProject do
  use Mix.Project
  def project do
    [app: :decimal_audit_probe, version: "0.0.0", deps: [],
     hex: [ignore_advisories: Fountain.Build.HexAdvisories.for_lock(Path.join(__DIR__, "mix.lock"))]]
  end
end
""")
lines = (root / "mix.lock").read_text().splitlines()
decimal = next(x for x in lines if x.startswith('  "decimal":'))
cowlib = next(x for x in lines if x.startswith('  "cowlib":'))
env = os.environ.copy()
env.pop("HEX_IGNORE_ADVISORIES", None)
env.pop("HEX_IGNORE_RETIREMENTS", None)
env["HEX_HOME"] = str(probe / "hex-home")
results = []
for name, entries, expected in [
    ("reviewed", decimal, 0),
    (
        "changed_checksum",
        decimal.replace(
            "430d87b04011ce6cbd4fd205be758311a81f87d552d40904abd00f015935b1d0", "0" * 64
        ),
        1,
    ),
    ("other_advisory", decimal + "\n" + cowlib, 1),
]:
    (probe / "mix.lock").write_text("%{\n" + entries + "\n}\n")
    result = subprocess.run(
        ["mise", "exec", "--", "elixir", str(root / "scripts/hex-audit-gate.exs")],
        cwd=probe,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=90,
    )
    log = output / (name + ".log")
    log.write_text(result.stdout)
    assert result.returncode == expected, (name, result.returncode, str(log))
    assert "EEF-CVE-2026-32686" in result.stdout, (name, "missing advisory")
    if expected:
        assert "Found packages with security advisories" in result.stdout, (
            name,
            "not an advisory refusal",
        )
    else:
        assert "Ignored advisories:" in result.stdout
    results.append({"case": name, "exit_code": result.returncode, "expected": expected})
print(
    json.dumps(
        {
            "results": results,
            "fresh_public_hex_cache": True,
            "provider_operations": 0,
            "output_directory": str(output),
        }
    )
)
