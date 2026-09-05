#!/usr/bin/env python3
"""Evaluate the shipped alert expressions with promtool (requires PyYAML)."""
from pathlib import Path
import subprocess
import tempfile

import yaml


ROOT = Path(__file__).resolve().parent.parent


def main():
    spec = yaml.safe_load((ROOT / "deploy/k8s/prometheusrule.yaml").read_text())["spec"]
    rules = {r["alert"]: r for g in spec["groups"] for r in g["rules"]}
    cases = []
    for replicas in (1, 2, 3):
        for alert, metric, statuses in (
            ("FountainSandboxBudgetExceeded", "fountain_sandboxes_count", ("pending", "ready")),
            ("FountainConversationsAboveBudget", "fountain_conversations_count", ("pending", "running")),
        ):
            for counts in ((10, 20), (20, 40)):
                series = [
                    {"series": f'{metric}{{namespace="fountain",status="{status}",pod="pod-{pod}"}}',
                     "values": f"{count}+0x120"}
                    for pod in range(replicas)
                    for status, count in zip(statuses, counts)
                ]
                total = sum(counts)
                cases.append({
                    "name": f"{alert}: {replicas} replicas, {total} rows",
                    "interval": "1m", "input_series": series,
                    "promql_expr_test": [{"expr": rules[alert]["expr"], "eval_time": "120m",
                                          "exp_samples": [{"labels": "{}", "value": total}] if total > 50 else []}],
                })

        for alert, state in (("FountainObanQueueBacklog", "available"),
                             ("FountainObanJobsDiscarded", "discarded")):
            for fires in (False, True):
                values = ("30+0x120" if fires else "20+0x120") if state == "available" else (
                    "0+0x59 1+0x60" if fires else "1+0x120")
                # Assert alert membership rather than delta's fractional
                # extrapolation, which differs between Prometheus 2 and 3.
                expression = rules[alert]["expr"]
                if state == "discarded":
                    expression = f"({expression.strip()}) > bool 0"
                value = 30 if state == "available" else 1
                series = [
                    {"series": f'fountain_oban_queue_depth{{namespace="fountain",queue="default",state="{state}",pod="pod-{pod}"}}',
                     "values": values}
                    for pod in range(replicas)
                ]
                # A second quiet queue must neither add to the first nor page.
                series.append({"series": f'fountain_oban_queue_depth{{namespace="fountain",queue="quiet",state="{state}",pod="pod-0"}}',
                               "values": "0+0x120"})
                cases.append({
                    "name": f"{alert}: {replicas} replicas, fires={fires}",
                    "interval": "1m", "input_series": series,
                    "promql_expr_test": [{"expr": expression, "eval_time": "120m",
                                          "exp_samples": [{"labels": f'{{namespace="fountain",queue="default",state="{state}"}}',
                                                           "value": value}] if fires else []}],
                })

    with tempfile.TemporaryDirectory(prefix="fountain-alert-tests-") as directory:
        rule_file = Path(directory) / "rules.yml"
        rule_file.write_text(yaml.safe_dump(spec))
        test_file = Path(directory) / "tests.yml"
        test_file.write_text(yaml.safe_dump({"rule_files": [str(rule_file)], "evaluation_interval": "1m", "tests": cases}))
        subprocess.run(["promtool", "check", "rules", str(rule_file)], check=True)
        subprocess.run(["promtool", "test", "rules", str(test_file)], check=True)
    print(f"Passed {len(cases)} alert expression cases")


if __name__ == "__main__":
    main()
