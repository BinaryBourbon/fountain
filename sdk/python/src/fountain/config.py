"""Credential and endpoint resolution shared by every client."""

from dataclasses import dataclass
import os
from pathlib import Path
from typing import Dict, Mapping, Optional

DEFAULT_BASE_URL = "https://managoat.com"
DEFAULT_APP_URL = "https://fountain-conversations.demo.managoat.com"


@dataclass(frozen=True)
class ResolvedConfig:
    base_url: str
    api_key: str
    app_url: str
    parent_conversation_id: Optional[str]


def parse_credentials(raw: str, profile: str) -> Dict[str, str]:
    """Parse the INI-like file written by ``fountain auth login``."""

    values: Dict[str, str] = {}
    section = ""
    for raw_line in raw.splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if section != profile or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1].strip()
        values[key.strip()] = value
    return values


def _read_credentials(profile: str, environ: Mapping[str, str]) -> Dict[str, str]:
    override = environ.get("FOUNTAIN_CREDENTIALS_FILE", "").strip()
    path = (
        Path(override).expanduser()
        if override
        else Path.home() / ".fountain" / "credentials"
    )
    try:
        return parse_credentials(path.read_text(encoding="utf-8"), profile)
    except (OSError, UnicodeError):
        return {}


def resolve_config(
    *,
    api_key: Optional[str] = None,
    base_url: Optional[str] = None,
    profile: Optional[str] = None,
    app_url: Optional[str] = None,
    environ: Optional[Mapping[str, str]] = None,
) -> ResolvedConfig:
    """Resolve options, environment variables, and the CLI credentials file."""

    env = os.environ if environ is None else environ
    selected_profile = (
        (profile or "").strip() or env.get("FOUNTAIN_PROFILE", "").strip() or "default"
    )
    credentials: Optional[Dict[str, str]] = None

    def creds() -> Dict[str, str]:
        nonlocal credentials
        if credentials is None:
            credentials = _read_credentials(selected_profile, env)
        return credentials

    key = (
        (api_key or "").strip()
        or env.get("FOUNTAIN_API_KEY", "").strip()
        or env.get("FOUNTAIN_TOKEN", "").strip()
        or creds().get("api_key", "")
    )
    endpoint = (
        (base_url or "").strip()
        or env.get("FOUNTAIN_BASE_URL", "").strip()
        or creds().get("base_url", "")
        or DEFAULT_BASE_URL
    )
    if app_url is None:
        app = env.get("FOUNTAIN_APP_URL", "").strip() or DEFAULT_APP_URL
    else:
        app = app_url.strip()
    return ResolvedConfig(
        base_url=endpoint.rstrip("/"),
        api_key=key,
        app_url=app.rstrip("/"),
        parent_conversation_id=env.get("FOUNTAIN_CONVERSATION_ID", "").strip() or None,
    )


def conversation_url(conversation_id: str, config: ResolvedConfig) -> str:
    if not config.app_url:
        return "%s/api/conversations/%s" % (config.base_url, conversation_id)
    return "%s/#/c/%s" % (config.app_url, conversation_id)
