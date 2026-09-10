#!/usr/bin/env python3
"""Print a ruleset update; --apply activates it after the checks pass on main."""

import argparse
import json
import subprocess


def api(path, payload=None):
    args = ["gh", "api", path]
    if payload is not None:
        args += ["--method", "PUT", "--input", "-"]
    result = subprocess.run(args, input=json.dumps(payload) if payload else None,
                            capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def updated_ruleset(current):
    # Keep review policy, bypass actors and unrelated rules exactly as fetched.
    result = {key: current[key] for key in
              ("name", "target", "enforcement", "conditions", "bypass_actors", "rules") if key in current}
    result = json.loads(json.dumps(result))
    checks = next((r for r in result["rules"] if r["type"] == "required_status_checks"), None)
    if checks is None:
        checks = {"type": "required_status_checks", "parameters": {
            "strict_required_status_checks_policy": True, "required_status_checks": [],
        }}
        result["rules"].append(checks)
    contexts = checks["parameters"]["required_status_checks"]
    for name in ("CI required", "Detect secrets"):
        # Bind to GitHub Actions rather than accepting a same-named status
        # from another integration. 15368 is GitHub Actions' app ID.
        existing = next((check for check in contexts if check["context"] == name), None)
        if existing is None:
            contexts.append({"context": name, "integration_id": 15368})
        else:
            existing["integration_id"] = 15368
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="managoat/fountain")
    parser.add_argument("--ruleset", default="21689465")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    path = f"repos/{args.repo}/rulesets/{args.ruleset}"
    payload = updated_ruleset(api(path))
    if args.apply:
        branch = api(f"repos/{args.repo}/branches/main")
        sha = branch["commit"]["sha"]
        runs = api(f"repos/{args.repo}/commits/{sha}/check-runs?per_page=100")["check_runs"]
        for name in ("CI required", "Detect secrets"):
            matches = [r for r in runs if r["name"] == name and r["app"]["id"] == 15368]
            latest = max(matches, key=lambda r: r["id"], default={})
            if latest.get("conclusion") != "success":
                raise SystemExit(f"Refusing activation: {name} has not passed on main ({sha}). Merge the workflow PR and wait for CI first.")
        api(path, payload)
        print(f"Required checks activated for {args.repo}.")
    else:
        print(json.dumps(payload, indent=2))
