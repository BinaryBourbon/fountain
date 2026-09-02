"""Fold a conversation's event feed into one turn."""

import json
from typing import Any, Dict, List, Optional

_TERMINAL_STATES = {"done", "failed", "interrupted"}


class TurnFollower:
    def __init__(self, turn_number: int, turn_id: Optional[str] = None) -> None:
        self.turn_number = turn_number
        self.turn_id = turn_id
        self.started = False
        self.state: Optional[str] = None
        self.exit_code: Optional[int] = None
        self.reason: Optional[str] = None
        self._chunks: List[str] = []
        self._tools: List[str] = []
        self._break_before_text = False

    @property
    def text(self) -> str:
        return "".join(self._chunks).strip()

    @property
    def tools_used(self) -> List[str]:
        return list(self._tools)

    @property
    def finished(self) -> bool:
        return self.state is not None

    def apply(self, event: Dict[str, Any]) -> List[Dict[str, Any]]:
        if event.get("kind") == "stage":
            return self._apply_stage(event)
        if event.get("kind") == "output":
            return self._apply_output(event)
        return []

    def _apply_stage(self, event: Dict[str, Any]) -> List[Dict[str, Any]]:
        if event.get("stage") != "turn":
            return []
        meta = _object(event.get("data"))
        if not self._matches(meta):
            return []
        state = event.get("state")
        if state == "started":
            self.started = True
            self.turn_id = _string(meta.get("turn_id")) or self.turn_id
            return [
                {
                    "type": "turn-start",
                    "turn_number": self.turn_number,
                    "turn_id": self.turn_id,
                }
            ]
        if state in _TERMINAL_STATES:
            self.state = state
            self.turn_id = self.turn_id or _string(meta.get("turn_id"))
            if isinstance(meta.get("exit_code"), int):
                self.exit_code = meta["exit_code"]
            self.reason = (
                _string(meta.get("reason"))
                or _string(meta.get("stop_reason"))
                or self.reason
            )
            return [
                {
                    "type": "turn-end",
                    "state": self.state,
                    "exit_code": self.exit_code,
                    "reason": self.reason,
                }
            ]
        return []

    def _matches(self, meta: Dict[str, Any]) -> bool:
        if self.turn_id and _string(meta.get("turn_id")) == self.turn_id:
            return True
        return meta.get("turn_number") == self.turn_number

    def _apply_output(self, event: Dict[str, Any]) -> List[Dict[str, Any]]:
        event_turn_id = _string(event.get("turn_id"))
        if self.turn_id and event_turn_id and event_turn_id != self.turn_id:
            return []
        if not self.started and not self.turn_id:
            return []
        output: List[Dict[str, Any]] = []
        for block in event.get("blocks") or []:
            if not isinstance(block, dict):
                continue
            output.append({"type": "block", "block": block, "event": event})
            output.extend(self._apply_block(block, event.get("stream") == "acp"))
        return output

    def _apply_block(self, block: Dict[str, Any], acp: bool) -> List[Dict[str, Any]]:
        kind = block.get("kind")
        body = block.get("body") if isinstance(block.get("body"), str) else ""
        if kind == "text":
            if not body:
                return []
            prefix = self._paragraph_break(acp)
            self._chunks.extend((prefix, body))
            self._break_before_text = False
            return [{"type": "text", "text": prefix + body}]
        if kind == "thinking":
            return [{"type": "thinking", "text": body}] if body else []
        if kind in ("raw", "init"):
            return []
        self._break_before_text = True
        if kind == "permission_request":
            request = _permission_request(block)
            return (
                [{"type": "permission", "request": request, "block": block}]
                if request
                else []
            )
        if kind == "tool_use":
            name = _string(block.get("name"))
            if not name:
                return []
            if name not in self._tools:
                self._tools.append(name)
            return [{"type": "tool", "name": name, "block": block}]
        if kind == "result" and not self._chunks and body:
            self._chunks.append(body)
            return [{"type": "text", "text": body}]
        if kind == "error" and body:
            text = "\n[error] %s\n" % body
            self._chunks.append(text)
            return [{"type": "text", "text": text}]
        return []

    def _paragraph_break(self, acp: bool) -> str:
        if not self._chunks or (acp and not self._break_before_text):
            return ""
        return "" if self._chunks[-1].endswith("\n") else "\n\n"


def _permission_request(block: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    request_id = _string(block.get("request_id"))
    if not request_id:
        return None
    options = []
    for raw in block.get("options") or []:
        if not isinstance(raw, dict):
            continue
        option_id = _string(raw.get("optionId")) or _string(raw.get("option_id"))
        if option_id:
            option = dict(raw)
            option["option_id"] = option_id
            options.append(option)
    if not options:
        return None
    return {
        "request_id": request_id,
        "summary": _string(block.get("summary")) or _string(block.get("body")),
        "tool_name": _string(block.get("name")),
        "tool_id": _string(block.get("tool_id")),
        "options": options,
    }


def _object(value: Any) -> Dict[str, Any]:
    if isinstance(value, dict):
        return value
    if not isinstance(value, str) or not value.strip():
        return {}
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _string(value: Any) -> Optional[str]:
    return value if isinstance(value, str) and value else None
