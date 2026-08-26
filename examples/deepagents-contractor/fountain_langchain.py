"""A Fountain agent as a LangChain runnable, tool, or Deep Agents subagent.

Everything here rides on Fountain's OpenAI-compatible API
(``POST /v1/chat/completions``, ADR 0035). The ``model`` is a Fountain agent.
The newest user message is the prompt; the sandbox keeps the rest of the
context, so nothing is replayed. One ``X-Fountain-Thread`` value is one
conversation is one sandbox.

Three shapes, one transport:

- ``FountainAgent(name)`` is a LangGraph-style runnable over ``{"messages"}``.
- ``FountainAgent(name).as_subagent(description)`` is a Deep Agents
  ``CompiledSubAgent`` the orchestrator delegates to with its ``task`` tool.
- ``FountainAgent(name).as_tool()`` is a plain LangChain tool for
  ``create_agent`` users who do not run Deep Agents.

Why not ``ChatOpenAI(base_url=...)``? Two reasons. A Fountain agent never
emits ``tool_calls`` (the tools ran in the sandbox; the answer is text), so it
cannot be the model inside a tool-calling loop; it is a leaf that returns one
report. And ``langchain-openai`` drops the non-standard ``reasoning_content``
deltas Fountain streams while a sandbox provisions, so a first turn looks hung
for a minute. The stock ``openai`` client keeps both honest.
"""

from __future__ import annotations

import os
import sys
import time
import uuid
from collections.abc import Callable
from typing import Any

from langchain_core.messages import AIMessage, BaseMessage, HumanMessage
from langchain_core.runnables import RunnableConfig, RunnableLambda
from langchain_core.tools import BaseTool, tool
from openai import APIStatusError, OpenAI

__all__ = ["FountainAgent", "list_fountain_agents"]

THREAD_HEADER = "X-Fountain-Thread"


def _client(base_url: str | None, api_key: str | None) -> OpenAI:
    base_url = base_url or os.environ.get("FOUNTAIN_OPENAI_BASE_URL")
    if not base_url:
        host = os.environ.get("FOUNTAIN_BASE_URL", "https://managoat.com").rstrip("/")
        base_url = f"{host}/v1"
    api_key = api_key or os.environ.get("FOUNTAIN_TOKEN") or os.environ.get("FOUNTAIN_API_KEY")
    if not api_key:
        raise RuntimeError("set FOUNTAIN_TOKEN (a Fountain API key) or pass api_key=")
    return OpenAI(base_url=base_url, api_key=api_key)


def list_fountain_agents(*, base_url: str | None = None, api_key: str | None = None) -> list[dict[str, Any]]:
    """The tenant's agents, as ``GET /v1/models`` reports them."""
    return [m.model_dump() for m in _client(base_url, api_key).models.list().data]


class FountainAgent:
    """One Fountain agent, addressable from LangChain.

    ``thread`` fixes the sandbox for the life of this object. Without it, the
    LangGraph ``thread_id`` in the ambient config is used (so one Deep Agents
    thread keeps one sandbox per Fountain agent across turns), and without
    that a random key is minted once per ``FountainAgent``.
    """

    def __init__(
        self,
        name: str,
        *,
        thread: str | None = None,
        system: str | None = None,
        base_url: str | None = None,
        api_key: str | None = None,
        on_reasoning: Callable[[str], None] | None = None,
        timeout: float = 3600.0,
    ) -> None:
        self.name = name
        self.system = system
        self._thread = thread
        self._fallback_thread = f"langchain-{uuid.uuid4().hex[:12]}"
        self._client = _client(base_url, api_key).with_options(timeout=timeout)
        self._on_reasoning = on_reasoning if on_reasoning is not None else _dim_stderr
        self._threads_seen: set[str] = set()

    # -- the three shapes ---------------------------------------------------

    def as_runnable(self) -> RunnableLambda:
        """``{"messages": [...]} -> {"messages": [AIMessage]}``, the shape Deep Agents reads."""
        return RunnableLambda(self._invoke_state, name=f"fountain:{self.name}")

    def as_subagent(self, description: str, *, name: str | None = None) -> dict[str, Any]:
        """A Deep Agents ``CompiledSubAgent``: ``name``, ``description``, ``runnable``.

        The subagent ``name`` is what the orchestrator types into ``task``, so
        it defaults to a slug of the agent's name (``Mend: a/b`` is easy to
        misspell; ``mend_a_b`` is not). The real name rides in the description.
        """
        return {
            "name": name or _slug(self.name),
            "description": f"{description} (Fountain agent '{self.name}')",
            "runnable": self.as_runnable(),
        }

    def as_tool(self, description: str | None = None) -> BaseTool:
        """A LangChain tool: ``prompt -> str``. Works with ``create_agent`` and any tool-calling loop."""
        agent = self
        doc = description or (
            f"Delegate a task to the Fountain agent '{self.name}'. It runs in its own sandbox "
            "with its own repositories and credentials and returns one report when it is done. "
            "Give it the whole task in one message; it remembers earlier tasks on the same thread."
        )

        @tool(f"fountain_{_slug(self.name)}", description=doc)
        def delegate(prompt: str, config: RunnableConfig) -> str:
            return agent.run(prompt, config=config)

        return delegate

    # -- the transport ------------------------------------------------------

    def run(self, prompt: str, *, config: RunnableConfig | None = None) -> str:
        """Send one prompt to the agent and return what it said, once the turn is over."""
        thread = self.thread_key(config)
        messages: list[dict[str, str]] = []
        if self.system and thread not in self._threads_seen:
            # Fountain delivers system only with the first prompt of a new thread.
            messages.append({"role": "system", "content": self.system})
        messages.append({"role": "user", "content": prompt})
        self._threads_seen.add(thread)

        for attempt in range(60):
            try:
                return self._stream(messages, thread)
            except APIStatusError as e:
                if e.status_code != 409:
                    raise
                # The thread is mid-turn. Fountain says how long to wait; it does not queue.
                wait = float(e.response.headers.get("Retry-After", "5"))
                self._on_reasoning(f"[{self.name} is busy; retrying in {wait:.0f}s]\n")
                time.sleep(wait)
        raise RuntimeError(f"{self.name}: thread {thread} stayed busy")

    def thread_key(self, config: RunnableConfig | None) -> str:
        if self._thread:
            return self._thread
        configurable = (config or {}).get("configurable") or {}
        thread_id = configurable.get("thread_id")
        if thread_id:
            return f"{thread_id}:{_slug(self.name)}"
        return self._fallback_thread

    def _stream(self, messages: list[dict[str, str]], thread: str) -> str:
        parts: list[str] = []
        stream = self._client.chat.completions.create(
            model=self.name,
            messages=messages,
            stream=True,
            extra_headers={THREAD_HEADER: thread},
        )
        for chunk in stream:
            if not chunk.choices:
                continue
            delta = chunk.choices[0].delta
            reasoning = getattr(delta, "reasoning_content", None) or (
                delta.model_extra or {}
            ).get("reasoning_content")
            if reasoning:
                self._on_reasoning(reasoning)
            if delta.content:
                parts.append(delta.content)
        return "".join(parts).strip()

    def _invoke_state(self, state: dict[str, Any], config: RunnableConfig) -> dict[str, Any]:
        prompt = _newest_human(state.get("messages", []))
        reply = self.run(prompt, config=config)
        return {"messages": [AIMessage(content=reply, name=self.name)]}


def _newest_human(messages: list[BaseMessage]) -> str:
    for m in reversed(messages):
        if isinstance(m, HumanMessage):
            return m.content if isinstance(m.content, str) else str(m.content)
    raise ValueError("no HumanMessage to send to Fountain")


def _slug(name: str) -> str:
    return "".join(c if c.isalnum() else "_" for c in name).strip("_").lower()


def _dim_stderr(text: str) -> None:
    if os.environ.get("FOUNTAIN_QUIET"):
        return
    sys.stderr.write(f"\033[2m{text}\033[0m")
    sys.stderr.flush()
