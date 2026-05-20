"""Tiny template renderer.

We use `string.Template` for substitution and provide a small helper that
loads a template file and substitutes mapping values, raising on any
missing key. Deliberately no Jinja dep — these templates only need
key substitution.
"""

from __future__ import annotations

from pathlib import Path
from string import Template


def render(template_path: str | Path, mapping: dict[str, str]) -> str:
    src = Path(template_path).read_text(encoding="utf-8")
    return Template(src).substitute(mapping)
