"""Load and validate config.toml.

The on-disk schema is intentionally permissive — we read what's there and
fall back to defaults. Secrets are pulled from environment variables when
the corresponding TOML field is blank.
"""

from __future__ import annotations

import os
import re
import shlex
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

_ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


@dataclass
class InfobloxConfig:
    host: str
    username: str
    password: str
    wapi_version: str = "v2.13.7"
    verify_tls: bool = False
    timeout: int = 10


@dataclass
class ReceiverConfig:
    listen_host: str = "0.0.0.0"
    listen_port: int = 6000
    mode: str = "tcp"
    advertised_host: str = ""
    advertised_port: int = 6000


@dataclass
class VectorConfig:
    version: str = "0.39.0"
    install_prefix: str = "/usr/local"
    config_path: str = "/etc/vector/vector.toml"
    data_dir: str = "/var/lib/vector"
    metrics_listen: str = "0.0.0.0:9598"
    jsonl_path: str = "/var/log/dnstap/events.jsonl"
    # NIOS-style query/response text lines on disk — input for a Splunk
    # Universal Forwarder when the indexer only exposes an S2S (splunktcp)
    # input, where HEC/raw TCP are unavailable. "" disables the sink.
    nios_log_path: str = ""


@dataclass
class PrometheusConfig:
    version: str = "2.53.0"
    install_prefix: str = "/usr/local"
    config_path: str = "/etc/prometheus/prometheus.yml"
    data_dir: str = "/var/lib/prometheus"
    listen: str = "0.0.0.0:9090"
    scrape_interval: str = "15s"


@dataclass
class SplunkConfig:
    enabled: bool = False
    hec_url: str = ""
    hec_token: str = ""
    index: str = "dns_dnstap"
    sourcetype: str = "infoblox:dns"
    source: str = "vector-dnstap"
    verify_tls: bool = True


@dataclass
class DnstapConfig:
    client_queries: bool = True
    client_responses: bool = True
    resolver_queries: bool = True
    resolver_responses: bool = True
    auth_queries: bool = False
    auth_responses: bool = False


@dataclass
class Config:
    infoblox: InfobloxConfig
    receiver: ReceiverConfig = field(default_factory=ReceiverConfig)
    vector: VectorConfig = field(default_factory=VectorConfig)
    prometheus: PrometheusConfig = field(default_factory=PrometheusConfig)
    splunk: SplunkConfig = field(default_factory=SplunkConfig)
    dnstap: DnstapConfig = field(default_factory=DnstapConfig)
    source_path: Path = field(default=Path("config.toml"))


def _env_file_values(path: Path) -> dict[str, str]:
    """Parse `export NAME='value'` lines from .env.dnstap2 (written by
    scripts/configure_local_settings.py) so tools that are not launched via
    setup.sh still see the stored secrets."""
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        try:
            parts = shlex.split(stripped, comments=True, posix=True)
        except ValueError:
            continue
        if parts and parts[0] == "export":
            parts = parts[1:]
        if len(parts) != 1 or "=" not in parts[0]:
            continue
        name, _, value = parts[0].partition("=")
        if _ENV_NAME_RE.match(name):
            values[name] = value
    return values


def _resolve_secret(value: str, env_var: str, env_file: dict[str, str] | None = None) -> str:
    """Return `value` if non-empty, else the env var, else the env-file value."""
    if value:
        return value
    return os.environ.get(env_var) or (env_file or {}).get(env_var, "")


def load(path: str | Path = "config.toml") -> Config:
    """Load config.toml from `path` and apply env-var fallbacks for secrets."""
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(
            f"{p} not found. Copy config.example.toml to config.toml and edit it."
        )
    with p.open("rb") as fp:
        raw = tomllib.load(fp)

    ib_raw = raw.get("infoblox", {})
    if "host" not in ib_raw or "username" not in ib_raw:
        raise ValueError("config.toml [infoblox] must define host and username")

    env_file = _env_file_values(
        Path(os.environ.get("DNSTAP2_ENV_FILE") or p.resolve().parent / ".env.dnstap2")
    )

    infoblox = InfobloxConfig(
        host=ib_raw["host"],
        username=ib_raw["username"],
        password=_resolve_secret(ib_raw.get("password", ""), "INFOBLOX_PASSWORD", env_file),
        wapi_version=ib_raw.get("wapi_version", "v2.13.7"),
        verify_tls=bool(ib_raw.get("verify_tls", False)),
        timeout=int(ib_raw.get("timeout", 10)),
    )

    receiver = ReceiverConfig(**raw.get("receiver", {}))
    vector = VectorConfig(**raw.get("vector", {}))
    prometheus = PrometheusConfig(**raw.get("prometheus", {}))

    sp_raw = raw.get("splunk", {})
    splunk = SplunkConfig(
        enabled=bool(sp_raw.get("enabled", False)),
        hec_url=sp_raw.get("hec_url", ""),
        hec_token=_resolve_secret(sp_raw.get("hec_token", ""), "SPLUNK_HEC_TOKEN", env_file),
        index=sp_raw.get("index", "dns_dnstap"),
        sourcetype=sp_raw.get("sourcetype", "infoblox:dns"),
        source=sp_raw.get("source", "vector-dnstap"),
        verify_tls=bool(sp_raw.get("verify_tls", True)),
    )

    dnstap = DnstapConfig(**raw.get("dnstap", {}))

    return Config(
        infoblox=infoblox,
        receiver=receiver,
        vector=vector,
        prometheus=prometheus,
        splunk=splunk,
        dnstap=dnstap,
        source_path=p.resolve(),
    )


def find_repo_root(start: Path | None = None) -> Path:
    """Walk up from `start` (or CWD) until we find config.example.toml."""
    cur = (start or Path.cwd()).resolve()
    for candidate in [cur, *cur.parents]:
        if (candidate / "config.example.toml").exists():
            return candidate
    raise RuntimeError("could not locate repo root (no config.example.toml found)")
