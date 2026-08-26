#!/usr/bin/env python3
"""A terminal chat with a Fountain agent, over the OpenAI-compatible API.

Nothing here is Fountain-specific except one header. The client is the stock
`openai` package pointed at `https://your-fountain/v1`; the model picker is
`GET /v1/models`; the reply is a normal streamed chat completion. The header
is what keeps a whole session in one sandbox.

    pip install openai
    export OPENAI_BASE_URL=https://your-fountain/v1
    export OPENAI_API_KEY=ftn_...          # Account -> API keys, or `fountain keys create`
    python chat.py                         # pick an agent, then chat
    python chat.py pr-reviewer             # or name one
    python chat.py pr-reviewer --thread prs-today   # resume a thread you named earlier

Walkthrough: https://managoat.com/docs/integrations/openai-compatible
"""

import argparse
import sys
import uuid

from openai import OpenAI


def pick_model(client: OpenAI) -> str:
    models = sorted(m.id for m in client.models.list())
    if not models:
        sys.exit("no agents on this account; create one in the console or with `fountain agent create`")
    if len(models) == 1:
        return models[0]
    for i, name in enumerate(models, 1):
        print(f"  {i}. {name}")
    while True:
        choice = input("agent> ").strip()
        if choice in models:
            return choice
        if choice.isdigit() and 1 <= int(choice) <= len(models):
            return models[int(choice) - 1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("model", nargs="?", help="the agent's name (default: choose from a list)")
    parser.add_argument(
        "--thread",
        default=None,
        help="the thread key; the same key resumes the same sandbox (default: a fresh one)",
    )
    parser.add_argument(
        "--system",
        default=None,
        help="a standing role, delivered once with the first message of a new thread",
    )
    parser.add_argument(
        "--quiet", action="store_true", help="hide the agent's reasoning and tool activity"
    )
    args = parser.parse_args()

    client = OpenAI()  # OPENAI_BASE_URL and OPENAI_API_KEY from the environment
    model = args.model or pick_model(client)
    thread = args.thread or f"chat-{uuid.uuid4().hex[:8]}"
    print(f"{model} on thread {thread}  (ctrl-d to quit; rerun with --thread {thread} to resume)")

    # The transcript is kept only because the request shape wants one. Fountain
    # reads the newest user message; the sandbox remembers the rest.
    history: list[dict] = []
    if args.system:
        history.append({"role": "system", "content": args.system})

    while True:
        try:
            line = input("\nyou> ").strip()
        except EOFError:
            print()
            return
        if not line:
            continue

        history.append({"role": "user", "content": line})
        reply, in_reasoning = [], False

        stream = client.chat.completions.create(
            model=model,
            messages=history,
            stream=True,
            extra_headers={"X-Fountain-Thread": thread},
        )
        print(f"{model}> ", end="", flush=True)
        for chunk in stream:
            if not chunk.choices:
                continue
            delta = chunk.choices[0].delta
            # Thinking, tool use and provisioning stages arrive here. Dimmed,
            # because it is what the agent did, not what it said.
            reasoning = getattr(delta, "reasoning_content", None)
            if reasoning and not args.quiet:
                if not in_reasoning:
                    print("\033[2m", end="")
                    in_reasoning = True
                print(reasoning, end="", flush=True)
            if delta.content:
                if in_reasoning:
                    print("\033[0m", end="")
                    in_reasoning = False
                print(delta.content, end="", flush=True)
                reply.append(delta.content)
        if in_reasoning:
            print("\033[0m", end="")
        print()

        history.append({"role": "assistant", "content": "".join(reply)})


if __name__ == "__main__":
    main()
