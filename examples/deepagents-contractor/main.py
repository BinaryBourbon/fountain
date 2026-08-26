"""A Deep Agent that plans, and Fountain agents that do the work.

    python main.py "Audit github.com/you/repo for stale docs and have fountain-contributor fix them"

The orchestrator is an ordinary tool-calling model (Anthropic here). Each
Fountain agent named on the command line becomes a subagent it can delegate to
with the built-in ``task`` tool. The subagent runs in its own Fountain sandbox
with its own repositories and credentials, and returns one report.
"""

from __future__ import annotations

import argparse
import os
import sys
import uuid

from deepagents import create_deep_agent
from fountain_langchain import FountainAgent, list_fountain_agents
from langchain_core.messages import AIMessage, ToolMessage

INSTRUCTIONS = """You are a project lead. You do not write code or run commands yourself.
You have contractors: the Fountain agents listed as subagents. Each one runs in its own
sandbox with the repositories and credentials it was hired with, works for as long as it
needs, and reports back once. Delegate concrete, self-contained tasks to them with the
`task` tool, read what comes back, and decide what to do next. When the job is done,
answer the user with what was delegated, what each contractor reported, and any links
(pull requests, commits) they gave you."""


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("prompt", nargs="?", help="what the lead should get done")
    p.add_argument("--agent", "-a", action="append", default=[], metavar="NAME[=DESCRIPTION]",
                   help="a Fountain agent to hire (repeatable); default: every agent on the account")
    p.add_argument("--model", default=os.environ.get("DEEPAGENTS_MODEL", "anthropic:claude-sonnet-5"),
                   help="the orchestrator model (a tool-calling model, not a Fountain agent)")
    p.add_argument("--thread", default=None, help="reuse a thread: same sandboxes, same memory")
    p.add_argument("--list", action="store_true", help="list the account's agents and exit")
    args = p.parse_args()

    if args.list or not args.prompt:
        for m in list_fountain_agents():
            f = m.get("fountain", {})
            print(f"{m['id']:40}  {f.get('runtime', ''):8}  {f.get('model', '')}")
        return

    hired = _hire(args.agent)
    agent = create_deep_agent(
        model=args.model,
        system_prompt=INSTRUCTIONS,
        subagents=[h.as_subagent(d) for h, d in hired],
    )

    thread_id = args.thread or f"contractor-{uuid.uuid4().hex[:8]}"
    config = {"configurable": {"thread_id": thread_id}, "recursion_limit": 100}
    print(f"thread {thread_id}  contractors: {', '.join(h.name for h, _ in hired)}\n", file=sys.stderr)

    final = None
    for chunk in agent.stream({"messages": [("user", args.prompt)]}, config=config, stream_mode="updates"):
        for node, update in chunk.items():
            for m in (update or {}).get("messages", []):
                if isinstance(m, AIMessage):
                    for call in m.tool_calls:
                        if call["name"] == "task":
                            a = call["args"]
                            print(f"\n→ {a.get('subagent_type')}: {a.get('description')}\n", file=sys.stderr)
                    if m.content:
                        final = m.content if isinstance(m.content, str) else str(m.content)
                elif isinstance(m, ToolMessage) and m.name == "task":
                    print(f"\n← report:\n{m.content}\n", file=sys.stderr)
    print(final or "(no final answer)")


def _hire(specs: list[str]) -> list[tuple[FountainAgent, str]]:
    if not specs:
        specs = [m["id"] for m in list_fountain_agents()]
    hired = []
    for spec in specs:
        name, _, desc = spec.partition("=")
        hired.append((FountainAgent(name), desc or f"The Fountain agent '{name}'. Delegate self-contained tasks to it."))
    return hired


if __name__ == "__main__":
    main()
