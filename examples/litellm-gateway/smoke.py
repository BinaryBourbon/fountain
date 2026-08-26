#!/usr/bin/env python3
"""Prove the gateway: three requests through LiteLLM, then look at what
Fountain saw. Nothing here is more than the stock `openai` package.

    pip install openai
    export OPENAI_BASE_URL=http://localhost:4000/v1   # the gateway, not Fountain
    export OPENAI_API_KEY=sk-local                    # LITELLM_MASTER_KEY, or a virtual key
    export FOUNTAIN_URL=https://managoat.com/v1       # only to read the conversation list back
    export FOUNTAIN_API_KEY=ftn_...
    python smoke.py fountain/reflex-1

What it checks, in order:

1. `GET /v1/models` on the gateway lists the agent.
2. Two streamed turns with the same `X-Fountain-Thread` land in ONE Fountain
   conversation, and the second remembers the first. This is the header the
   gateway must forward (`forward_client_headers_to_llm_api: true`).
3. A request with no header and `safety_identifier: <name>` lands in a
   conversation of its own, on channel `openai:<name>`. LiteLLM drops the
   `user` field (OpenAI retired it) and forwards this one, so it is the
   body-level key that survives the hop; Fountain reads it third.
"""

import os
import sys
import uuid

import httpx  # ships with `openai`
from openai import OpenAI


def conversations(channel: str) -> list[dict]:
    """The conversations Fountain bound to a thread key, over the real API."""
    base = os.environ["FOUNTAIN_URL"].removesuffix("/v1")
    resp = httpx.get(
        f"{base}/api/conversations",
        params={"channel_id": f"openai:{channel}"},
        headers={"Authorization": f"Bearer {os.environ['FOUNTAIN_API_KEY']}"},
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()["data"]


def turn(client: OpenAI, model: str, prompt: str, **kw) -> str:
    print(f"\n> {prompt}")
    stream = client.chat.completions.create(
        model=model, messages=[{"role": "user", "content": prompt}], stream=True, **kw
    )
    text = []
    for chunk in stream:
        if not chunk.choices:
            continue
        delta = chunk.choices[0].delta
        reasoning = getattr(delta, "reasoning_content", None)
        if reasoning:
            print(f"\033[2m{reasoning}\033[0m", end="", flush=True, file=sys.stderr)
        if delta.content:
            text.append(delta.content)
            print(delta.content, end="", flush=True)
    print()
    return "".join(text)


def check(cond: bool, what: str) -> None:
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        sys.exit(1)


def main() -> None:
    model = sys.argv[1] if len(sys.argv) > 1 else "fountain/reflex-1"
    client = OpenAI()  # OPENAI_BASE_URL and OPENAI_API_KEY: the gateway

    # 1. The picker.
    ids = [m.id for m in client.models.list()]
    check(model in ids, f"{model} is in the gateway's model list ({len(ids)} models)")

    # 2. The header, forwarded, keeps two turns in one sandbox.
    thread = f"smoke-{uuid.uuid4().hex[:8]}"
    headers = {"X-Fountain-Thread": thread}
    turn(client, model, "Remember the word 'pelican'. Reply with only: noted.", extra_headers=headers)
    reply = turn(client, model, "Which word did I ask you to remember? One word.", extra_headers=headers)
    convs = conversations(thread)
    check(len(convs) == 1, f"one conversation on channel openai:{thread} (got {len(convs)})")
    check("pelican" in reply.lower(), "the second turn remembered the first")

    # 3. `safety_identifier`, with no header, is a thread of its own. (`user`
    #    would be, straight against Fountain; LiteLLM drops it on the way.)
    person = f"smoke-user-{uuid.uuid4().hex[:8]}"
    turn(client, model, "Reply with only: hello.", safety_identifier=person)
    check(len(conversations(person)) == 1, f"one conversation on channel openai:{person}")

    print("\nall good. Conversation ids:", [c["id"] for c in convs + conversations(person)])


if __name__ == "__main__":
    main()
