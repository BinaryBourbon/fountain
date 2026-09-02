"""Check the Python SDK's wire assumptions against the server contract.

The server owns the API shape, while this client reaches into a deliberately
small part of it by hand. This check keeps those assumptions close to the
client so a breaking server change fails before it reaches an SDK user.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
from typing import Any, Dict, List


SDK = "python"
_CONTRACT_DIR = Path(__file__).resolve().parents[2] / "contract"
_CONTRACT_PATH = _CONTRACT_DIR / "contract.json"
_MANIFEST_PATH = _CONTRACT_DIR / "manifests" / (SDK + ".json")


def _read_json(path: Path) -> Dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("the top-level JSON value is not an object")
    return value


def _format_problem(scenario: str, detail: str) -> str:
    return "  %s\n      %s" % (scenario, detail)


def _check(contract: Dict[str, Any], manifest: Dict[str, Any]) -> List[str]:
    problems: List[str] = []

    def fail(scenario: str, detail: str) -> None:
        problems.append(_format_problem(scenario, detail))

    operations = contract.get("operations", {})
    for operation in manifest.get("operations", []):
        if operation not in operations:
            fail(
                "operation %s" % operation,
                "the API no longer serves it. Update the client, or drop it from the manifest.",
            )

    schemas = contract.get("schemas", {})
    for name, declared in manifest.get("schemas", {}).items():
        if name not in schemas:
            fail("schema %s" % name, "the API no longer defines it.")
            continue

        schema = schemas[name]
        properties = schema.get("properties", {})

        def check(field: str, expectation: str) -> None:
            if field not in properties:
                fail(
                    "%s.%s" % (name, field),
                    "the API no longer has this property. It has: %s"
                    % ", ".join(sorted(properties)),
                )
                return

            prop = properties[field]
            if expectation == "required" and prop.get("required") is not True:
                fail(
                    "%s.%s" % (name, field),
                    "this client reads it as always present, but the API no longer requires it.",
                )
            if expectation == "optional" and prop.get("required") is True:
                fail(
                    "%s.%s" % (name, field),
                    "this client omits it, but the API now requires it.",
                )

        for field in declared.get("required", []):
            check(field, "required")
        for field in declared.get("optional", []):
            check(field, "optional")
        for field in declared.get("fields", []):
            check(field, "present")

    for path, declared in manifest.get("enums", {}).items():
        name, field = path.split(".", 1)
        schema = schemas.get(name)
        properties = schema.get("properties", {}) if schema else {}
        if field not in properties:
            fail("enum %s" % path, "the API no longer has this property.")
            continue

        accepted = properties[field].get("enum")
        if not isinstance(accepted, list):
            fail(
                "enum %s" % path,
                "the API no longer constrains this property to an enum.",
            )
            continue

        values = declared if isinstance(declared, list) else declared.get("values", [])
        missing = [value for value in values if value not in accepted]
        if missing:
            fail(
                "enum %s" % path,
                "this client handles %s, which the API no longer accepts. It now accepts: %s"
                % (
                    ", ".join(str(value) for value in missing),
                    ", ".join(str(value) for value in accepted),
                ),
            )
        if not isinstance(declared, list) and declared.get("exhaustive") is True:
            extra = [value for value in accepted if value not in values]
            if extra:
                fail(
                    "enum %s" % path,
                    "this client claims to handle every value but the API added: %s"
                    % ", ".join(str(value) for value in extra),
                )

    return problems


def check_contract() -> List[str]:
    """Return every mismatch between this SDK's manifest and the contract."""

    return _check(_read_json(_CONTRACT_PATH), _read_json(_MANIFEST_PATH))


def main() -> int:
    try:
        contract = _read_json(_CONTRACT_PATH)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        print(
            "error: cannot read the wire contract (%s): %s"
            % (_CONTRACT_PATH, error),
            file=sys.stderr,
        )
        return 1
    try:
        manifest = _read_json(_MANIFEST_PATH)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        print(
            "error: cannot read the SDK manifest (%s): %s"
            % (_MANIFEST_PATH, error),
            file=sys.stderr,
        )
        return 1

    problems = _check(contract, manifest)
    if problems:
        print(
            "SDK contract check FAILED for %s (%s problems)\n"
            % (SDK, len(problems)),
            file=sys.stderr,
        )
        for problem in problems:
            print(problem + "\n", file=sys.stderr)
        print(
            "The server's wire contract moved. Update sdk/python to match, then\n"
            "adjust sdk/contract/manifests/python.json. See sdk/contract/README.md.",
            file=sys.stderr,
        )
        return 1

    counts = "%s operations, %s schemas, %s enums" % (
        len(manifest.get("operations", [])),
        len(manifest.get("schemas", {})),
        len(manifest.get("enums", {})),
    )
    print("SDK contract check ok for %s (%s)" % (SDK, counts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
