"""CRUD wrappers for Fountain's named resources."""

from typing import Any, Dict, List, Optional, cast
from urllib.parse import quote

from .http import HttpClient
from .resolve import Resolver


class Collection:
    def __init__(
        self, http: HttpClient, resolver: Resolver, path: str, what: str
    ) -> None:
        self._http = http
        self._resolver = resolver
        self._path = path
        self._what = what

    def list(self, search: Optional[str] = None) -> List[Dict[str, Any]]:
        return self._http.list(self._path, query={"search": search})

    def get(self, name_or_id: str) -> Dict[str, Any]:
        resource_id = self._resolver.resolve(self._path, self._what, name_or_id)["id"]
        return self._http.data("GET", "%s/%s" % (self._path, resource_id))

    def create(self, input: Dict[str, Any]) -> Dict[str, Any]:
        created = self._http.data("POST", self._path, body=input)
        self._resolver.forget(self._path)
        return created

    def update(self, name_or_id: str, patch: Dict[str, Any]) -> Dict[str, Any]:
        resource_id = self._resolver.resolve(self._path, self._what, name_or_id)["id"]
        updated = self._http.data(
            "PATCH", "%s/%s" % (self._path, resource_id), body=patch
        )
        self._resolver.forget(self._path)
        return updated

    def delete(self, name_or_id: str) -> None:
        resource_id = self._resolver.resolve(self._path, self._what, name_or_id)["id"]
        self._http.request("DELETE", "%s/%s" % (self._path, resource_id))
        self._resolver.forget(self._path)


class Secrets:
    def __init__(
        self, http: HttpClient, resolver: Resolver, parent_path: str, what: str
    ) -> None:
        self._http = http
        self._resolver = resolver
        self._parent_path = parent_path
        self._what = what

    def list(self, parent: str) -> List[Dict[str, Any]]:
        return self._http.list("%s/secrets" % self._parent(parent))

    def set(self, parent: str, key: str, value: str) -> Dict[str, Any]:
        return self._http.data(
            "POST",
            "%s/secrets" % self._parent(parent),
            body={"key": key, "value": value},
        )

    def set_all(self, parent: str, secrets: Dict[str, str]) -> List[Dict[str, Any]]:
        base = self._parent(parent)
        return [
            self._http.data(
                "POST", "%s/secrets" % base, body={"key": key, "value": value}
            )
            for key, value in secrets.items()
        ]

    def delete(self, parent: str, key: str) -> None:
        self._http.request(
            "DELETE", "%s/secrets/%s" % (self._parent(parent), quote(key, safe=""))
        )

    def _parent(self, name_or_id: str) -> str:
        resource_id = self._resolver.resolve(self._parent_path, self._what, name_or_id)[
            "id"
        ]
        return "%s/%s" % (self._parent_path, resource_id)


class Agents(Collection):
    def __init__(self, http: HttpClient, resolver: Resolver) -> None:
        super().__init__(http, resolver, "/api/agents", "agent")


class Environments(Collection):
    def __init__(self, http: HttpClient, resolver: Resolver) -> None:
        super().__init__(http, resolver, "/api/environments", "environment")
        self.secrets = Secrets(http, resolver, self._path, self._what)


class Vaults(Collection):
    def __init__(self, http: HttpClient, resolver: Resolver) -> None:
        super().__init__(http, resolver, "/api/vaults", "vault")
        self.secrets = Secrets(http, resolver, self._path, self._what)


class Connections:
    def __init__(self, http: HttpClient) -> None:
        self._http = http
        self.providers = ConnectionProviders(http)

    def list(self) -> List[Dict[str, Any]]:
        return self._http.list("/api/connections")

    def get(self, connection_id: str) -> Dict[str, Any]:
        return cast(
            Dict[str, Any],
            self._http.request(
                "GET", "/api/connections/%s" % quote(connection_id, safe="")
            ),
        )

    def delete(self, connection_id: str) -> None:
        self._http.request(
            "DELETE", "/api/connections/%s" % quote(connection_id, safe="")
        )


class ConnectionProviders:
    def __init__(self, http: HttpClient) -> None:
        self._http = http

    def list(self) -> List[Dict[str, Any]]:
        return self._http.list("/api/connection-providers")

    def get(self, provider_id: str) -> Dict[str, Any]:
        return cast(
            Dict[str, Any],
            self._http.request(
                "GET", "/api/connection-providers/%s" % quote(provider_id, safe="")
            ),
        )

    def create(self, input: Dict[str, Any]) -> Dict[str, Any]:
        return cast(
            Dict[str, Any],
            self._http.request("POST", "/api/connection-providers", body=input),
        )

    def update(self, provider_id: str, patch: Dict[str, Any]) -> Dict[str, Any]:
        return cast(
            Dict[str, Any],
            self._http.request(
                "PATCH",
                "/api/connection-providers/%s" % quote(provider_id, safe=""),
                body=patch,
            ),
        )

    def delete(self, provider_id: str) -> None:
        self._http.request(
            "DELETE", "/api/connection-providers/%s" % quote(provider_id, safe="")
        )

    def discover(self, provider_id: str) -> Dict[str, Any]:
        return cast(
            Dict[str, Any],
            self._http.request(
                "POST",
                "/api/connection-providers/%s/discover" % quote(provider_id, safe=""),
            ),
        )
