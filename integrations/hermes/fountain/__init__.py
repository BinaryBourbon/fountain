"""Hermes plugin: Fountain agents as tools.

Registers seven tools (`fountain_agents`, `fountain_run`, `fountain_send`,
`fountain_wait`, `fountain_status`, `fountain_conversations`,
`fountain_terminate`), a `fountain:fountain` skill that explains when to reach
for them, and a `/fountain` slash command for humans.

Install: symlink or copy this directory to `~/.hermes/plugins/fountain/`, or
`hermes plugins install BinaryBourbon/fountain/integrations/hermes/fountain --enable`.
Configure with `FOUNTAIN_API_KEY` (+ `FOUNTAIN_BASE_URL` for a self-hosted
instance), `fountain auth login`, or `plugins.entries.fountain.settings.*`.
"""

from __future__ import annotations

import json
import logging
import shlex
from pathlib import Path

from . import schemas
from .client import FountainClient, FountainError, resolve_settings
from .tools import FountainTools

logger = logging.getLogger(__name__)

TOOLSET = "fountain"

_HELP = """/fountain — Fountain agents from Hermes
  /fountain agents [search]            list agents
  /fountain run <agent> <prompt…>      start a conversation and wait for the answer
  /fountain send <conversation_id> <prompt…>
  /fountain wait <conversation_id>
  /fountain status <conversation_id>
  /fountain conversations              live conversations
  /fountain terminate <conversation_id>
  /fountain whoami                     which instance and key source are in use"""


def _settings(ctx) -> dict:
    def get(key: str, default=None):
        try:
            val = ctx.get_config(key, default=default)
        except Exception:  # config access is best-effort — env/credentials still work
            return default
        return default if val is None else val

    return {
        "base_url": str(get("base_url", "") or ""),
        "api_key": str(get("api_key", "") or ""),
        "profile": str(get("profile", "") or ""),
        "default_timeout_seconds": get("default_timeout_seconds", 300),
    }


def register(ctx):
    settings = _settings(ctx)

    def resolve() -> tuple[str, str]:
        return resolve_settings(
            base_url=settings["base_url"], api_key=settings["api_key"], profile=settings["profile"]
        )

    def client_factory() -> FountainClient:
        base_url, api_key = resolve()
        return FountainClient(base_url, api_key)

    def configured() -> bool:
        _, key = resolve()
        return bool(key)

    try:
        default_timeout = float(settings["default_timeout_seconds"] or 300)
    except (TypeError, ValueError):
        default_timeout = 300.0

    tools = FountainTools(client_factory, default_timeout=default_timeout)

    handlers = {
        "fountain_agents": tools.agents,
        "fountain_run": tools.run,
        "fountain_send": tools.send,
        "fountain_wait": tools.wait,
        "fountain_status": tools.status,
        "fountain_conversations": tools.conversations,
        "fountain_terminate": tools.terminate,
    }
    for schema in schemas.ALL:
        ctx.register_tool(
            name=schema["name"],
            toolset=TOOLSET,
            schema=schema,
            handler=handlers[schema["name"]],
            check_fn=configured,
            emoji="⛲",
        )

    skill_md = Path(__file__).parent / "skills" / "fountain" / "SKILL.md"
    if skill_md.exists():
        try:
            ctx.register_skill("fountain", skill_md, description="Delegating work to Fountain agents")
        except Exception as exc:  # older Hermes without register_skill
            logger.debug("fountain plugin: register_skill unavailable: %s", exc)

    def slash(raw_args: str) -> str:
        return _slash(raw_args, tools, resolve)

    try:
        ctx.register_command(
            "fountain",
            slash,
            description="Run and inspect Fountain agents",
            args_hint="agents | run <agent> <prompt> | send <id> <prompt> | wait <id> | status <id> | conversations | terminate <id>",
        )
    except Exception as exc:
        logger.debug("fountain plugin: register_command unavailable: %s", exc)


def _slash(raw_args: str, tools: FountainTools, resolve) -> str:
    try:
        parts = shlex.split(raw_args or "")
    except ValueError:
        parts = (raw_args or "").split()
    if not parts or parts[0] in ("help", "-h", "--help"):
        return _HELP
    cmd, rest = parts[0], parts[1:]

    if cmd == "whoami":
        base_url, key = resolve()
        return f"instance: {base_url}\napi key: {'configured' if key else 'MISSING'}"
    if cmd == "agents":
        return _pretty(tools.agents({"search": " ".join(rest) or None}))
    if cmd == "run":
        if len(rest) < 2:
            return "usage: /fountain run <agent> <prompt…>"
        return _pretty(tools.run({"agent": rest[0], "prompt": " ".join(rest[1:])}))
    if cmd == "send":
        if len(rest) < 2:
            return "usage: /fountain send <conversation_id> <prompt…>"
        return _pretty(tools.send({"conversation_id": rest[0], "prompt": " ".join(rest[1:])}))
    if cmd == "wait":
        if not rest:
            return "usage: /fountain wait <conversation_id>"
        return _pretty(tools.wait({"conversation_id": rest[0]}))
    if cmd == "status":
        if not rest:
            return "usage: /fountain status <conversation_id>"
        return _pretty(tools.status({"conversation_id": rest[0]}))
    if cmd in ("conversations", "convs", "ls"):
        return _pretty(tools.conversations({}))
    if cmd == "terminate":
        if not rest:
            return "usage: /fountain terminate <conversation_id>"
        return _pretty(tools.terminate({"conversation_id": rest[0]}))
    return f"unknown subcommand {cmd!r}\n\n{_HELP}"


def _pretty(result_json: str) -> str:
    try:
        data = json.loads(result_json)
    except ValueError:
        return result_json
    if isinstance(data, dict) and "error" in data:
        return f"error: {data['error']}"
    if isinstance(data, dict) and "output" in data:
        head = {k: v for k, v in data.items() if k != "output"}
        return json.dumps(head, indent=2, default=str) + "\n\n" + (data.get("output") or "(no output)")
    return json.dumps(data, indent=2, default=str)


__all__ = ["register", "FountainClient", "FountainError", "FountainTools"]
