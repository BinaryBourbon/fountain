"""The small amount of vocabulary the HTTP schema cannot express."""

from dataclasses import dataclass
from typing import Any, Dict, List, Optional

JsonObject = Dict[str, Any]


@dataclass(frozen=True)
class RunResult:
    """One completed turn."""

    conversation_id: str
    url: str
    turn_number: int
    text: str
    tools_used: List[str]
    state: str
    exit_code: Optional[int]
    reason: Optional[str]
    status: Optional[str]
    events: Optional[List[JsonObject]] = None


@dataclass(frozen=True)
class SandboxFile:
    """Bytes read from a sandbox and whether the server cut them at its limit."""

    data: bytes
    truncated: bool
