#!/usr/bin/env python3
"""Smoke Fountain through LiteLLM, then inspect the real conversation API.

Required environment:

    OPENAI_BASE_URL=http://localhost:4000/v1
    OPENAI_API_KEY=sk-local
    FOUNTAIN_URL=https://managoat.com/v1
    FOUNTAIN_API_KEY=ftn_...

Run with: python smoke.py fountain/reflex-1
"""

import os
import sys
import uuid

import httpx
from openai import OpenAI


def conversations(thread: str) -> list[dict]:
    """Return Fountain conversations bound to an OpenAI thread key."""
    base = os.environ["FOUNTAIN_URL"].removesuffix("/v1")
    response = httpx.get(
        f"{base}/api/conversations",
        params={"channel_id": f"openai:{thread}"},
        headers={"Authorization": f"Bearer {os.environ['FOUNTAIN_API_KEY']}"},
        timeout=30,
    )
    response.raise_for_status()
    return response.json()["data"]


def turn(client: OpenAI, model: str, prompt: str, **kwargs: object) -> str:
    print(f"\n> {prompt}")
    stream = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": prompt}],
        stream=True,
        **kwargs,
    )

    output = []
    for chunk in stream:
        if not chunk.choices:
            continue

        delta = chunk.choices[0].delta
        reasoning = getattr(delta, "reasoning_content", None)
        if reasoning:
            print(f"\033[2m{reasoning}\033[0m", end="", flush=True, file=sys.stderr)
        if delta.content:
            output.append(delta.content)
            print(delta.content, end="", flush=True)

    print()
    return "".join(output)


def check(condition: bool, message: str) -> None:
    print(("  ok   " if condition else "  FAIL ") + message)
    if not condition:
        raise SystemExit(1)


def main() -> None:
    model = sys.argv[1] if len(sys.argv) > 1 else "fountain/reflex-1"
    client = OpenAI(max_retries=0, timeout=1800)

    model_ids = [item.id for item in client.models.list()]
    check(model in model_ids, f"{model} is in the gateway model list")

    thread = f"smoke-{uuid.uuid4().hex[:8]}"
    headers = {"X-Fountain-Thread": thread}
    turn(
        client,
        model,
        "Remember the word 'pelican'. Reply with only: noted.",
        extra_headers=headers,
    )
    reply = turn(
        client,
        model,
        "Which word did I ask you to remember? One word.",
        extra_headers=headers,
    )
    threaded = conversations(thread)
    check(len(threaded) == 1, f"one conversation on channel openai:{thread}")
    check("pelican" in reply.lower(), "the second turn remembered the first")

    person = f"smoke-user-{uuid.uuid4().hex[:8]}"
    turn(client, model, "Reply with only: hello.", safety_identifier=person)
    body_keyed = conversations(person)
    check(len(body_keyed) == 1, f"one conversation on channel openai:{person}")

    ids = [conversation["id"] for conversation in threaded + body_keyed]
    print("\nall good. Conversation ids:", ids)


if __name__ == "__main__":
    main()
