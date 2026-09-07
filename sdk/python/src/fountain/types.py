"""The small amount of vocabulary the HTTP schema cannot express."""

from dataclasses import dataclass
from typing import Any, Dict, List, Optional, TypedDict

JsonObject = Dict[str, Any]


class ExecutionLimits(TypedDict, total=False):
    """Per-turn controls, subject to server capability checks and ceilings."""

    wall_time_seconds: int
    max_model_turns: int
    max_estimated_cost_usd: float


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
