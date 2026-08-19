"""A scripted in-process Fountain for the plugin tests.

Serves the slice of the API the plugin uses. Tests append log events and flip
statuses between polls to script a turn; the server never sleeps.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TOKEN = "fk_test_token"


class State:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.agents = [
            {"id": "a-1", "name": "reviewer", "runtime": "claude", "model": "opus", "description": "reviews"},
            {"id": "a-2", "name": "Builder", "runtime": "codex", "model": "gpt-5", "description": None},
            {"id": "a-3", "name": "builder-two", "runtime": "codex", "model": "gpt-5", "description": None},
        ]
        self.vaults = [{"id": "v-1", "name": "prod-keys"}]
        self.environments = [{"id": "e-1", "name": "py312"}]
        self.conversations: dict[str, dict] = {}
        self.turns: dict[str, list[dict]] = {}
        self.events: dict[str, list[dict]] = {}
        self.requests: list[tuple[str, str, dict | None, dict]] = []
        self.next_conv = 1
        self.next_event = 1
        # Called (with the state) at the start of every GET so a test can
        # advance the script per poll.
        self.on_poll = None

    # ── scripting helpers ─────────────────────────────────────────────────

    def add_event(self, conv_id: str, **ev) -> int:
        with self.lock:
            eid = self.next_event
            self.next_event += 1
            row = {"id": eid, "kind": ev.get("kind", "output"), "stream": ev.get("stream"),
                   "data": ev.get("data", ""), "stage": ev.get("stage"), "state": ev.get("state"),
                   "turn_id": ev.get("turn_id"), "ts": "2026-08-19T00:00:00Z"}
            if "blocks" in ev:
                row["blocks"] = ev["blocks"]
            elif row["kind"] == "output":
                row["blocks"] = []
            self.events.setdefault(conv_id, []).append(row)
            return eid

    def stage(self, conv_id: str, state: str, turn_number: int, turn_id: str, **meta) -> int:
        return self.add_event(conv_id, kind="stage", stage="turn", state=state,
                              data=json.dumps({"turn_id": turn_id, "turn_number": turn_number, **meta}))

    def text(self, conv_id: str, turn_id: str, body: str, stream: str = "acp") -> int:
        return self.add_event(conv_id, kind="output", stream=stream, turn_id=turn_id,
                              blocks=[{"kind": "text", "body": body}])

    def tool(self, conv_id: str, turn_id: str, name: str) -> int:
        return self.add_event(conv_id, kind="output", stream="acp", turn_id=turn_id,
                              blocks=[{"kind": "tool_use", "id": "t1", "name": name, "summary": name, "body": {}}])

    def set_status(self, conv_id: str, status: str) -> None:
        with self.lock:
            self.conversations[conv_id]["status"] = status

    def add_turn(self, conv_id: str, prompt: str) -> dict:
        with self.lock:
            turns = self.turns.setdefault(conv_id, [])
            turn = {"id": f"t-{conv_id}-{len(turns) + 1}", "turn_number": len(turns) + 1,
                    "prompt": prompt, "status": "pending", "exit_code": None,
                    "started_at": None, "ended_at": None}
            turns.append(turn)
            self.conversations[conv_id]["turn_count"] = len(turns)
            return turn


class Handler(BaseHTTPRequestHandler):
    state: State  # set by the server factory

    def log_message(self, *_):  # silence
        pass

    def _send(self, code: int, body) -> None:
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _auth(self) -> bool:
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self._send(401, {"error": "unauthorized"})
            return False
        return True

    def _body(self) -> dict | None:
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return None
        return json.loads(self.rfile.read(n))

    def do_GET(self):
        st = self.state
        if not self._auth():
            return
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        st.requests.append(("GET", url.path, None, dict(self.headers)))
        if st.on_poll:
            st.on_poll(st)
        parts = url.path.strip("/").split("/")
        if url.path == "/api/agents":
            agents = st.agents
            if q.get("search"):
                agents = [a for a in agents if q["search"].lower() in a["name"].lower()]
            return self._send(200, {"data": agents})
        if url.path == "/api/vaults":
            return self._send(200, {"data": st.vaults})
        if url.path == "/api/environments":
            return self._send(200, {"data": st.environments})
        if url.path == "/api/conversations":
            return self._send(200, {"data": list(st.conversations.values())})
        if len(parts) >= 3 and parts[1] == "conversations":
            conv = st.conversations.get(parts[2])
            if not conv:
                return self._send(404, {"error": "not_found"})
            if len(parts) == 3:
                return self._send(200, {"data": conv})
            if parts[3] == "turns":
                return self._send(200, {"data": st.turns.get(parts[2], [])})
            if parts[3] == "events":
                after = int(q.get("after") or 0)
                limit = int(q.get("limit") or 100)
                rows = [e for e in st.events.get(parts[2], []) if e["id"] > after]
                page, more = rows[:limit], len(rows) > limit
                out = []
                for e in page:
                    e = dict(e)
                    if q.get("blocks") != "true":
                        e.pop("blocks", None)
                    out.append(e)
                return self._send(200, {"data": out, "meta": {"limit": limit, "has_more": more,
                                                              "next_cursor": page[-1]["id"] if page else None}})
        return self._send(404, {"error": "not_found"})

    def do_POST(self):
        st = self.state
        if not self._auth():
            return
        url = urlparse(self.path)
        body = self._body()
        st.requests.append(("POST", url.path, body, dict(self.headers)))
        parts = url.path.strip("/").split("/")
        if url.path == "/api/conversations":
            agent = next((a for a in st.agents if a["id"] == body.get("agent_id")), None)
            if not agent:
                return self._send(404, {"error": "not_found"})
            with st.lock:
                cid = f"c-{st.next_conv}"
                st.next_conv += 1
                st.conversations[cid] = {"id": cid, "title": None, "status": "pending", "agent_id": agent["id"],
                                         "vault_id": body.get("vault_id"), "environment_id": body.get("environment_id"),
                                         "runtime": agent["runtime"], "turn_count": 0}
            if body.get("prompt"):
                st.add_turn(cid, body["prompt"])
            return self._send(201, {"data": st.conversations[cid]})
        if len(parts) == 4 and parts[1] == "conversations":
            conv = st.conversations.get(parts[2])
            if not conv:
                return self._send(404, {"error": "not_found"})
            if parts[3] == "prompts":
                if conv["status"] == "running":
                    return self._send(409, {"error": "conversation_busy"})
                st.add_turn(parts[2], body["prompt"])
                return self._send(200, {"status": "queued"})
            if parts[3] == "terminate":
                st.set_status(parts[2], "terminated")
                return self._send(200, {"data": conv})
            if parts[3] == "interrupt":
                return self._send(200, {"data": conv})
        return self._send(404, {"error": "not_found"})


class FakeFountain:
    def __init__(self) -> None:
        self.state = State()
        handler = type("BoundHandler", (Handler,), {"state": self.state})
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self) -> "FakeFountain":
        self.thread.start()
        return self

    def __exit__(self, *_) -> None:
        self.server.shutdown()
        self.server.server_close()

    @property
    def base_url(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}"
