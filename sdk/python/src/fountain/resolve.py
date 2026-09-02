"""Resolve human-friendly resource names to API ids."""

import re
import threading
from typing import Any, Dict, List, Optional

from .errors import ResolutionError
from .http import HttpClient

_UUID = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I
)


class Resolver:
    def __init__(self, http: HttpClient) -> None:
        self._http = http
        self._cache: Dict[str, List[Dict[str, Any]]] = {}
        self._lock = threading.Lock()

    def clear(self) -> None:
        with self._lock:
            self._cache.clear()

    def forget(self, path: str) -> None:
        with self._lock:
            self._cache.pop(path, None)

    def list(self, path: str) -> List[Dict[str, Any]]:
        with self._lock:
            cached = self._cache.get(path)
        if cached is not None:
            return cached
        items = self._http.list(path)
        with self._lock:
            self._cache[path] = items
        return items

    def resolve(self, path: str, what: str, name_or_id: str) -> Dict[str, Any]:
        wanted = (name_or_id or "").strip()
        if not wanted:
            raise ResolutionError("%s is required (a name or id)" % what)
        if _UUID.match(wanted):
            with self._lock:
                known = next(
                    (
                        item
                        for item in self._cache.get(path, [])
                        if item.get("id") == wanted
                    ),
                    None,
                )
            return known or {"id": wanted}

        items = self.list(path)
        by_id = next((item for item in items if item.get("id") == wanted), None)
        if by_id:
            return by_id
        lower = wanted.lower()
        exact = [item for item in items if str(item.get("name", "")).lower() == lower]
        if len(exact) == 1:
            return exact[0]
        if len(exact) > 1:
            raise ResolutionError(
                "More than one %s is named %r. Use the id: %s"
                % (what, wanted, ", ".join(str(item["id"]) for item in exact))
            )
        prefix = [
            item
            for item in items
            if str(item.get("name", "")).lower().startswith(lower)
        ]
        if len(prefix) == 1:
            return prefix[0]
        if len(prefix) > 1:
            raise ResolutionError(
                "%r matches more than one %s: %s"
                % (
                    wanted,
                    what,
                    ", ".join(str(item.get("name") or item["id"]) for item in prefix),
                )
            )
        names = sorted(str(item.get("name") or item.get("id")) for item in items)
        raise ResolutionError(
            "No %s named %r. On this account: %s"
            % (what, wanted, ", ".join(names) or "(none)")
        )

    def resolve_id(
        self, path: str, what: str, name_or_id: Optional[str]
    ) -> Optional[str]:
        return str(self.resolve(path, what, name_or_id)["id"]) if name_or_id else None
