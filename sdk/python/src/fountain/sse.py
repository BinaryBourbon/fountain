"""SSE parsing and reconnecting Fountain event streams."""

import json
import threading
import time
from typing import Any, Dict, Iterable, Iterator, List, Mapping, Optional

from .errors import ConnectionError, FountainError
from .http import HttpClient, Response


def parse_sse(lines: Iterable[bytes]) -> Iterator[Dict[str, Optional[str]]]:
    """Parse an iterable of SSE lines. Heartbeat comments are omitted."""

    event_id: Optional[str] = None
    event = "message"
    data: List[str] = []

    for raw in lines:
        line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
        if not line:
            if data or event_id is not None:
                yield {"id": event_id, "event": event, "data": "\n".join(data)}
            event_id, event, data = None, "message", []
            continue
        if line.startswith(":"):
            continue
        field, separator, value = line.partition(":")
        if separator and value.startswith(" "):
            value = value[1:]
        if field == "id":
            event_id = value
        elif field == "event":
            event = value
        elif field == "data":
            data.append(value)

    if data or event_id is not None:
        yield {"id": event_id, "event": event, "data": "\n".join(data)}


def _response_lines(response: Response) -> Iterator[bytes]:
    while True:
        line = response.readline()
        if not line:
            return
        yield line


def _decode_event(message: Mapping[str, Optional[str]]) -> Optional[Dict[str, Any]]:
    raw = message.get("data")
    if not raw:
        return None
    try:
        payload = json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    try:
        event_id = int(message.get("id") or "")
    except ValueError:
        event_id = 0
    if event_id > 0:
        payload["id"] = event_id
    event_name = message.get("event")
    if not payload.get("kind") and event_name in ("output", "stage"):
        payload["kind"] = event_name
    return payload


def stream_path(
    http: HttpClient,
    path: str,
    *,
    after: int = 0,
    streams: Optional[str] = None,
    wait: bool = True,
    blocks: bool = False,
    max_retries: int = 5,
    retry_delay: float = 0.5,
    stop: Optional[threading.Event] = None,
    deadline: Optional[float] = None,
) -> Iterator[Dict[str, Any]]:
    """Read any Fountain SSE endpoint and reconnect from its last event id."""

    last_id = after
    attempt = 0
    while not (stop and stop.is_set()):
        if deadline is not None and time.monotonic() >= deadline:
            return
        headers = {"Last-Event-ID": str(last_id)} if last_id > 0 else None
        timeout = None
        if deadline is not None:
            timeout = max(0.001, deadline - time.monotonic())
        response: Optional[Response] = None
        response_done: Optional[threading.Event] = None
        try:
            response = http.raw(
                "GET",
                path,
                query={
                    "blocks": "true" if blocks else None,
                    "streams": streams,
                    "wait": "false" if not wait else None,
                },
                headers=headers,
                accept="text/event-stream",
                timeout=timeout,
            )
            if stop is not None:
                response_done = threading.Event()
                threading.Thread(
                    target=_close_when_stopped,
                    args=(response, stop, response_done),
                    name="fountain-stream-cancel",
                    daemon=True,
                ).start()
            attempt = 0
            for message in parse_sse(_response_lines(response)):
                if stop and stop.is_set():
                    return
                event = _decode_event(message)
                if event is None:
                    # A cut connection flushes a partial trailing message.
                    # Holding the cursor back asks for that event again.
                    continue
                try:
                    parsed_id = int(message.get("id") or "")
                except ValueError:
                    parsed_id = 0
                if parsed_id > 0:
                    last_id = parsed_id
                yield event
        except (FountainError, OSError, ValueError) as error:
            if isinstance(error, FountainError) and not _reconnectable(error):
                raise
            if (stop and stop.is_set()) or (
                deadline is not None and time.monotonic() >= deadline
            ):
                return
            attempt += 1
            if attempt > max_retries:
                raise
            _delay(retry_delay * attempt, stop, deadline)
            continue
        finally:
            if response_done is not None:
                response_done.set()
            if response is not None:
                response.close()

        if not wait:
            return
        attempt += 1
        if attempt > max_retries:
            return
        _delay(retry_delay, stop, deadline)


def stream_events(
    http: HttpClient, conversation_id: str, **options: Any
) -> Iterator[Dict[str, Any]]:
    options.setdefault("blocks", True)
    return stream_path(
        http, "/api/conversations/%s/stream" % conversation_id, **options
    )


def _reconnectable(error: FountainError) -> bool:
    """A dropped connection or a 5xx is worth another attempt; a 4xx is not."""

    return isinstance(error, ConnectionError) or 500 <= error.status < 600


def _delay(
    seconds: float, stop: Optional[threading.Event], deadline: Optional[float]
) -> None:
    if deadline is not None:
        seconds = min(seconds, max(0.0, deadline - time.monotonic()))
    if seconds <= 0:
        return
    if stop:
        stop.wait(seconds)
    else:
        time.sleep(seconds)


def _close_when_stopped(
    response: Response, stop: threading.Event, done: threading.Event
) -> None:
    while not done.wait(0.05):
        if stop.is_set():
            response.close()
            return
