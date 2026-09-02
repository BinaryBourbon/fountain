"""The public Fountain client."""

from typing import Any, Dict, Iterator, List, Optional, Union, cast

from .config import ResolvedConfig, resolve_config
from .conversation import Conversation
from .http import HttpClient, Transport
from .resolve import Resolver
from .resources import Agents, Connections, Environments, Vaults
from .run import Run
from .sse import stream_path
from .team import Team
from .types import SandboxFile


class Fountain:
    def __init__(
        self,
        *,
        api_key: Optional[str] = None,
        base_url: Optional[str] = None,
        profile: Optional[str] = None,
        app_url: Optional[str] = None,
        timeout: Optional[float] = 30.0,
        transport: Optional[Transport] = None,
    ) -> None:
        self.config: ResolvedConfig = resolve_config(
            api_key=api_key, base_url=base_url, profile=profile, app_url=app_url
        )
        self.api = HttpClient(self.config, timeout=timeout, transport=transport)
        self._resolver = Resolver(self.api)
        self.agents = Agents(self.api, self._resolver)
        self.environments = Environments(self.api, self._resolver)
        self.vaults = Vaults(self.api, self._resolver)
        self.team = Team(self.api, self._resolver)
        self.connections = Connections(self.api)

    def run(
        self,
        prompt: str,
        *,
        agent: str,
        vault: Optional[str] = None,
        environment: Optional[str] = None,
        title: Optional[str] = None,
        images: Optional[List[Dict[str, Any]]] = None,
        channel_id: Optional[str] = None,
        fresh: bool = False,
        sprite_name: Optional[str] = None,
        sandbox: Optional[str] = None,
        sandbox_mode: Optional[str] = None,
        timeout: Optional[float] = None,
        collect_events: bool = False,
    ) -> Run:
        def plan() -> Any:
            selected_agent = self._resolver.resolve("/api/agents", "agent", agent)
            vault_id = self._resolver.resolve_id("/api/vaults", "vault", vault)
            environment_id = self._resolver.resolve_id(
                "/api/environments", "environment", environment
            )
            body: Dict[str, Any] = {"agent_id": selected_agent["id"]}
            optional = {
                "prompt": prompt or None,
                "vault_id": vault_id,
                "environment_id": environment_id,
                "title": title,
                "images": images or None,
                "channel_id": channel_id,
                "fresh": True if fresh else None,
                "sprite_name": sprite_name,
                "sandbox_id": sandbox,
                "sandbox_mode": sandbox_mode,
            }
            body.update(
                {key: value for key, value in optional.items() if value is not None}
            )
            conversation = self.api.data("POST", "/api/conversations", body=body)
            turn_number = (
                self._next_turn_number(str(conversation["id"])) if channel_id else 1
            )
            return conversation, turn_number, 0

        return Run(self.api, plan, timeout=timeout, collect_events=collect_events)

    def resume(self, conversation_id: str) -> Conversation:
        return Conversation(self.api, conversation_id)

    def conversations(self, *, roots_only: bool = True) -> List[Dict[str, Any]]:
        return self.api.list(
            "/api/conversations", query={"roots_only": "true" if roots_only else None}
        )

    def me(self) -> Dict[str, Any]:
        return cast(Dict[str, Any], self.api.request("GET", "/api/auth/me"))

    def catalog(self) -> Dict[str, Any]:
        return self.api.data("GET", "/api/catalog")

    def sandboxes(self, *, status: Optional[List[str]] = None) -> List[Dict[str, Any]]:
        return self.api.list(
            "/api/sandboxes", query={"status": ",".join(status) if status else None}
        )

    def sandbox(self, sandbox_id: str) -> Dict[str, Any]:
        return self.api.data("GET", "/api/sandboxes/%s" % sandbox_id)

    def reset_sandbox(self, sandbox_id: str) -> None:
        self.api.request("DELETE", "/api/sandboxes/%s" % sandbox_id)

    def exec_sandbox(
        self,
        sandbox_id: str,
        command: str,
        *,
        args: Optional[List[str]] = None,
        cwd: Optional[str] = None,
        timeout_ms: Optional[int] = None,
    ) -> Dict[str, Any]:
        """Run a command on a ready sandbox and wait for it."""

        body: Dict[str, Any] = {"command": command}
        if args:
            body["args"] = args
        if cwd is not None:
            body["cwd"] = cwd
        if timeout_ms is not None:
            body["timeout_ms"] = timeout_ms
        request_timeout = (
            (timeout_ms / 1000.0 + 5.0) if timeout_ms is not None else 65.0
        )
        return self.api.data(
            "POST",
            "/api/sandboxes/%s/exec" % sandbox_id,
            body=body,
            timeout=request_timeout,
        )

    def read_sandbox_file(self, sandbox_id: str, path: str) -> SandboxFile:
        """Read one file's bytes from a ready sandbox."""

        response = self.api.raw(
            "GET",
            "/api/sandboxes/%s/files" % sandbox_id,
            query={"path": path},
            accept="application/octet-stream",
        )
        try:
            truncated = (
                str(response.headers.get("X-Fountain-Truncated", "false")).lower()
                == "true"
            )
            return SandboxFile(response.read(), truncated)
        finally:
            response.close()

    def search(
        self, query: str, *, limit: Optional[int] = None
    ) -> List[Dict[str, Any]]:
        return self.api.list("/api/search", query={"q": query, "limit": limit})

    def events(
        self,
        *,
        streams: Optional[Union[List[str], str]] = None,
        **options: Any,
    ) -> Iterator[Dict[str, Any]]:
        selected = ",".join(streams) if isinstance(streams, list) else streams
        return stream_path(
            self.api, "/api/events/stream", streams=selected, blocks=True, **options
        )

    def refresh(self) -> None:
        self._resolver.clear()

    def request(self, method: str, path: str, **options: Any) -> Any:
        return self.api.request(method, path, **options)

    def _next_turn_number(self, conversation_id: str) -> int:
        turns = self.api.list("/api/conversations/%s/turns" % conversation_id)
        return max((int(turn.get("turn_number") or 0) for turn in turns), default=0) + 1
