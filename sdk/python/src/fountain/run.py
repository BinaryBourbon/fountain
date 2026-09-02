"""A turn that starts immediately and can be waited on or streamed."""

import json
import asyncio
import threading
import time
from typing import (
    Any,
    AsyncIterator,
    Callable,
    Generator,
    Iterator,
    List,
    Optional,
    Tuple,
    cast,
)

from .config import conversation_url
from .errors import TimeoutError
from .http import HttpClient
from .sse import stream_events
from .turn import TurnFollower
from .types import JsonObject, RunResult

RunPlan = Callable[[], Tuple[JsonObject, int, int]]
_TERMINAL_CONVERSATION_STATUSES = {"failed", "terminated"}
_END = object()


class _Broadcast:
    def __init__(self) -> None:
        self._items: List[JsonObject] = []
        self._condition = threading.Condition()
        self._closed = False
        self._error: Optional[BaseException] = None

    def push(self, item: JsonObject) -> None:
        with self._condition:
            if not self._closed:
                self._items.append(item)
                self._condition.notify_all()

    def close(self, error: Optional[BaseException] = None) -> None:
        with self._condition:
            self._closed = True
            self._error = error
            self._condition.notify_all()

    def iterate(self) -> Iterator[JsonObject]:
        index = 0
        while True:
            with self._condition:
                while index >= len(self._items) and not self._closed:
                    self._condition.wait()
                if index < len(self._items):
                    item = self._items[index]
                    index += 1
                elif self._error is not None:
                    raise self._error
                else:
                    return
            yield item


class Run:
    """A turn in flight.

    Work begins in a daemon thread at construction. Iterate the handle for
    events, iterate ``text_stream`` for words, or call :meth:`result`.
    """

    def __init__(
        self,
        http: HttpClient,
        plan: RunPlan,
        *,
        timeout: Optional[float] = None,
        collect_events: bool = False,
    ) -> None:
        self._http = http
        self._plan = plan
        self._timeout = timeout
        self._collect_events = collect_events
        self._events = _Broadcast()
        self._cancel = threading.Event()
        self._opened = threading.Event()
        self._completed = threading.Event()
        self._conversation: Optional[JsonObject] = None
        self._result: Optional[RunResult] = None
        self._error: Optional[BaseException] = None
        self._cursor = 0
        self._on_finish: List[Callable[["Run"], None]] = []
        threading.Thread(target=self._execute, name="fountain-run", daemon=True).start()

    def __iter__(self) -> Iterator[JsonObject]:
        return self._events.iterate()

    def __await__(self) -> Generator[Any, None, RunResult]:
        return self._async_result().__await__()

    def __aiter__(self) -> AsyncIterator[JsonObject]:
        return self._async_events()

    @property
    def text_stream(self) -> Iterator[str]:
        return (event["text"] for event in self if event.get("type") == "text")

    @property
    def async_text_stream(self) -> AsyncIterator[str]:
        return self._async_text_events()

    def result(self, timeout: Optional[float] = None) -> RunResult:
        """Wait for the turn. ``timeout`` here only limits this caller's wait."""

        if not self._completed.wait(timeout):
            raise TimeoutError(
                "Timed out waiting for the local Run handle", self.id or "", ""
            )
        if self._error is not None:
            raise self._error
        assert self._result is not None
        return self._result

    @property
    def conversation(self) -> JsonObject:
        self._wait_until_open()
        assert self._conversation is not None
        return self._conversation

    @property
    def conversation_id(self) -> str:
        return str(self.conversation["id"])

    @property
    def url(self) -> str:
        return conversation_url(self.conversation_id, self._http.config)

    @property
    def cursor(self) -> int:
        return self._cursor

    @property
    def id(self) -> Optional[str]:
        value = self._conversation.get("id") if self._conversation else None
        return str(value) if value else None

    def cancel(self) -> None:
        """Stop this SDK's wait. The agent keeps running."""

        self._cancel.set()

    def answer(self, request_id: str, option_id: str) -> None:
        self._http.request(
            "POST",
            "/api/conversations/%s/requests/%s"
            % (self.conversation_id, _quote(request_id)),
            body={"option_id": option_id},
        )

    def interrupt(self) -> None:
        self._http.request(
            "POST", "/api/conversations/%s/interrupt" % self.conversation_id
        )

    def terminate(self) -> None:
        self._http.request(
            "POST", "/api/conversations/%s/terminate" % self.conversation_id
        )

    def _after_finish(self, callback: Callable[["Run"], None]) -> None:
        self._on_finish.append(callback)
        if self._completed.is_set():
            callback(self)

    def _wait_until_open(self) -> None:
        self._opened.wait()
        if self._error is not None and self._conversation is None:
            raise self._error

    async def _async_result(self) -> RunResult:
        return await asyncio.to_thread(self.result)

    async def _async_events(self) -> AsyncIterator[JsonObject]:
        iterator = iter(self)
        while True:
            item = await asyncio.to_thread(_next_or_end, iterator)
            if item is _END:
                return
            yield cast(JsonObject, item)

    async def _async_text_events(self) -> AsyncIterator[str]:
        async for event in self:
            if event.get("type") == "text":
                yield str(event["text"])

    def _execute(self) -> None:
        try:
            conversation, turn_number, after = self._plan()
            self._conversation = conversation
            self._cursor = after
            self._opened.set()
            url = conversation_url(str(conversation["id"]), self._http.config)
            self._events.push(
                {
                    "type": "conversation",
                    "conversation_id": conversation["id"],
                    "conversation": conversation,
                    "url": url,
                }
            )
            self._result = self._follow(conversation, turn_number, after, url)
            self._events.close()
        except BaseException as error:
            self._error = error
            self._opened.set()
            self._events.close(error)
        finally:
            self._completed.set()
            for callback in self._on_finish:
                try:
                    callback(self)
                except Exception:
                    pass

    def _follow(
        self, conversation: JsonObject, turn_number: int, after: int, url: str
    ) -> RunResult:
        follower = TurnFollower(turn_number)
        collected: List[JsonObject] = []
        deadline = (
            time.monotonic() + self._timeout
            if self._timeout and self._timeout > 0
            else None
        )
        failure_reason: Optional[str] = None

        for event in stream_events(
            self._http,
            str(conversation["id"]),
            after=after,
            stop=self._cancel,
            deadline=deadline,
        ):
            event_id = event.get("id")
            if isinstance(event_id, int):
                self._cursor = max(self._cursor, event_id)
            if self._collect_events:
                collected.append(event)
            self._events.push({"type": "event", "event": event})
            for output in follower.apply(event):
                self._events.push(output)
            if follower.finished:
                break
            if _may_end_conversation(event):
                status = self._current_status(conversation)
                if status in _TERMINAL_CONVERSATION_STATUSES:
                    failure_reason = _stage_reason(event)
                    break

        if (
            deadline is not None
            and time.monotonic() >= deadline
            and not follower.finished
        ):
            assert self._timeout is not None
            raise TimeoutError(
                "Timed out after %.3fs waiting for turn %s. The turn is still running — resume conversation %s."
                % (self._timeout, turn_number, conversation["id"]),
                str(conversation["id"]),
                follower.text,
            )

        status = self._current_status(conversation)
        if not follower.finished:
            state = "failed" if failure_reason else "timeout"
            self._events.push(
                {
                    "type": "turn-end",
                    "state": state,
                    "exit_code": None,
                    "reason": failure_reason,
                }
            )
        return RunResult(
            conversation_id=str(conversation["id"]),
            url=url,
            turn_number=turn_number,
            text=follower.text,
            tools_used=follower.tools_used,
            state=follower.state or ("failed" if failure_reason else "timeout"),
            exit_code=follower.exit_code,
            reason=follower.reason or failure_reason,
            status=status,
            events=collected if self._collect_events else None,
        )

    def _current_status(self, conversation: JsonObject) -> Optional[str]:
        try:
            fresh = self._http.data("GET", "/api/conversations/%s" % conversation["id"])
            value = (
                fresh.get("status")
                if isinstance(fresh, dict)
                else conversation.get("status")
            )
        except Exception:
            value = conversation.get("status")
        return value if isinstance(value, str) else None


def _quote(value: str) -> str:
    from urllib.parse import quote

    return quote(value, safe="")


def _may_end_conversation(event: JsonObject) -> bool:
    return (
        event.get("kind") == "stage"
        and event.get("stage") != "turn"
        and (
            event.get("state") == "failed"
            or event.get("stage") in ("terminate", "sandbox")
        )
    )


def _stage_reason(event: JsonObject) -> Optional[str]:
    meta: Any = event.get("data")
    if isinstance(meta, str):
        try:
            meta = json.loads(meta)
        except json.JSONDecodeError:
            return None
    if not isinstance(meta, dict):
        return None
    reason = meta.get("message", meta.get("reason"))
    label = reason if isinstance(reason, str) and reason else None
    base = "%s/%s" % (event.get("stage"), event.get("state"))
    return "%s: %s" % (base, label) if label else base


def _next_or_end(iterator: Iterator[JsonObject]) -> Any:
    try:
        return next(iterator)
    except StopIteration:
        return _END
