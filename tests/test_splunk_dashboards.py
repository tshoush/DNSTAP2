"""Guards for the Splunk dashboards in ``splunk/``.

These dashboards are hand-edited Simple XML. The tests keep them honest:
- every ``.xml`` parses as well-formed XML (a stray ``&`` or ``<`` breaks import);
- the POC ``mi_dhcp`` boards keep referencing the index and the two receiver
  ``source`` values the field extraction and A/B split rely on;
- the documented dashboards all exist on disk.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
SPLUNK_DIR = REPO_ROOT / "splunk"

# index -> dashboards that must target it (and reference the right sources)
MI_DHCP_DASHBOARDS = ("dns_dnstap_ab_overview.xml", "dns_dnstap_filterable.xml")
ALL_DASHBOARDS = ("dns_dnstap_overview.xml",) + MI_DHCP_DASHBOARDS


def _xml_files() -> list[Path]:
    return sorted(SPLUNK_DIR.glob("*.xml"))


def test_dashboards_present() -> None:
    """Every dashboard the docs point at exists."""
    for name in ALL_DASHBOARDS:
        assert (SPLUNK_DIR / name).is_file(), f"missing dashboard: {name}"


@pytest.mark.parametrize("xml_file", _xml_files(), ids=lambda p: p.name)
def test_dashboard_is_well_formed(xml_file: Path) -> None:
    """A malformed dashboard fails to import in Splunk — catch it here."""
    root = ET.parse(xml_file).getroot()
    # Simple XML dashboards are a <form> or <dashboard> root.
    assert root.tag in {"form", "dashboard"}, f"unexpected root <{root.tag}> in {xml_file.name}"


@pytest.mark.parametrize("name", MI_DHCP_DASHBOARDS)
def test_mi_dhcp_dashboards_reference_index_and_sources(name: str) -> None:
    """The POC boards must query mi_dhcp and split on both receiver sources."""
    text = (SPLUNK_DIR / name).read_text()
    assert "index=mi_dhcp" in text, f"{name} no longer queries index=mi_dhcp"
    assert "dnstap:vector" in text, f"{name} dropped the Vector source"
    assert "dnstap:dnscollector" in text, f"{name} dropped the DNS-collector source"


@pytest.mark.parametrize("name", MI_DHCP_DASHBOARDS)
def test_mi_dhcp_dashboards_handle_both_dnstap_legs(name: str) -> None:
    """Extraction must cover RESOLVER_* too, or resolver responses misclassify."""
    text = (SPLUNK_DIR / name).read_text()
    assert "RESOLVER" in text, f"{name} only handles the CLIENT_* leg"
