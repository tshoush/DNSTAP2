"""Load and validate config.toml.

The on-disk schema is intentionally permissive — we read what's there and
fall back to defaults. Secrets are pulled from environment variables when
the corresponding TOML field is blank.
"""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path


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
    sourcetype: str = "dnstap:json"
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


def _resolve_secret(value: str, env_var: str) -> str:
    """Return `value` if non-empty, else os.environ.get(env_var, '')."""
    if value:
        return value
    return os.environ.get(env_var, "")


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

    infoblox = InfobloxConfig(
        host=ib_raw["host"],
        username=ib_raw["username"],
        password=_resolve_secret(ib_raw.get("password", ""), "INFOBLOX_PASSWORD"),
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
        hec_token=_resolve_secret(sp_raw.get("hec_token", ""), "SPLUNK_HEC_TOKEN"),
        index=sp_raw.get("index", "dns_dnstap"),
        sourcetype=sp_raw.get("sourcetype", "dnstap:json"),
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
