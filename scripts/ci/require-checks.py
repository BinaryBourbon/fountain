#!/usr/bin/env python3
"""Print a ruleset update; --apply activates it after the checks pass on main."""

import argparse
import base64
import json
import subprocess


def api(path, payload=None, method="PUT"):
    args = ["gh", "api", path]
    if payload is not None:
        args += ["--method", method, "--input", "-"]
    result = subprocess.run(args, input=json.dumps(payload) if payload else None,
                            capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


# Sized against this repo's measured CI, not GitHub's defaults.
#
# max_entries_to_build: 1 — the org is on the free plan, which allows 20
# concurrent GitHub-hosted jobs. A full mixed PR runs 26 jobs; a merge group
# runs 27 because both probes run. Speculating
# two groups deep cannot run two groups; it queues the second behind the first
# while also starving every open PR. Raise this only after the concurrency
# ceiling does.
#
# min_entries_to_merge: 2 with a 5 minute wait — batching is the only lever
# that buys throughput under that same ceiling, because five PRs merged as one
# group cost one 27-job run instead of five. In a burst the group fills at once
# and nothing waits; in a quiet hour a lone PR waits up to five minutes, which
# is the hour where nobody is blocked on it.
#
# ALLGREEN, not HEADGREEN: a group merges only when every entry passed, which
# is the entire reason to run a queue over a tree nobody tested.
MERGE_QUEUE = {
    "check_response_timeout_minutes": 60,
    "grouping_strategy": "ALLGREEN",
    "max_entries_to_build": 1,
    "max_entries_to_merge": 5,
    "merge_method": "SQUASH",
    "min_entries_to_merge": 2,
    "min_entries_to_merge_wait_minutes": 5,
}


def updated_ruleset(current, merge_queue=False):
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
    if merge_queue:
        # "Up to date" was an approximation of "tested against what it will
        # actually merge into". The queue tests that directly, so keeping both
        # only forces rebases to prove what the queue is about to prove
        # properly — and every one of those rebases costs another PR run.
        checks["parameters"]["strict_required_status_checks_policy"] = False
        rule = next((r for r in result["rules"] if r["type"] == "merge_queue"), None)
        if rule is None:
            rule = {"type": "merge_queue"}
            result["rules"].append(rule)
        rule["parameters"] = dict(MERGE_QUEUE)
        # The review requirement is deliberately NOT touched here. A queue
        # answers "does this tree build", which is a different question from
        # "did anyone read it", and on a repository where most PRs are written
        # by agents the second question is the one worth keeping. The cost is
        # that an approval has to come from somewhere before a PR can be
        # queued at all: GitHub will not enqueue a PR whose merge requirements
        # are unmet, so an unreviewed PR simply never enters.
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="managoat/fountain")
    parser.add_argument("--ruleset", default="21689465")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--merge-queue", action="store_true",
                        help="also add the merge queue rule and drop the up-to-date requirement")
    args = parser.parse_args()
    path = f"repos/{args.repo}/rulesets/{args.ruleset}"
    payload = updated_ruleset(api(path), merge_queue=args.merge_queue)
    if args.apply:
        branch = api(f"repos/{args.repo}/branches/main")
        sha = branch["commit"]["sha"]
        runs = api(f"repos/{args.repo}/commits/{sha}/check-runs?per_page=100")["check_runs"]
        for name in ("CI required", "Detect secrets"):
            matches = [r for r in runs if r["name"] == name and r["app"]["id"] == 15368]
            latest = max(matches, key=lambda r: r["id"], default={})
            if latest.get("conclusion") != "success":
                raise SystemExit(f"Refusing activation: {name} has not passed on main ({sha}). Merge the workflow PR and wait for CI first.")
        if args.merge_queue:
            # The order that bricks the repo: turn the queue on while main's
            # workflows still only answer push and pull_request. Every queued
            # PR then waits for a check that never starts, times out after
            # check_response_timeout_minutes and is ejected — with no failing
            # job anywhere to explain why. Verify main can answer first.
            for workflow in ("ci.yml", "secrets-scan.yml"):
                body = api(f"repos/{args.repo}/contents/.github/workflows/{workflow}?ref={sha}")
                if "merge_group" not in base64.b64decode(body["content"]).decode():
                    raise SystemExit(
                        f"Refusing activation: {workflow} on main ({sha[:7]}) has no merge_group "
                        "trigger, so its required check would never run for a queued PR.")
            # A queue entry IS an auto-merge, so the repository has to allow
            # one. Without this `gh pr merge --auto` errors and there is no
            # other way in: the ruleset accepts the queue rule regardless, and
            # the result is a queue nothing can reach.
            api(f"repos/{args.repo}", {"allow_auto_merge": True}, method="PATCH")
        api(path, payload)
        print(f"Required checks activated for {args.repo}.")
    else:
        print(json.dumps(payload, indent=2))
