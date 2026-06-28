# DNSTAP2 — Documentation Index

## POC decision: native DNS query logging vs. dnstap
| Document | Purpose |
|---|---|
| [poc-evaluation-plan.md](poc-evaluation-plan.md) | The decision plan — weighted scorecard, 11 technical tests, cost (3-yr TCO) & implementation analysis, risks, go/no-go framework |
| [jira-stories.md](jira-stories.md) | Execution backlog — 6 epics, 19 stories (62 pts) with acceptance criteria |
| [jira-stories.csv](jira-stories.csv) | The same backlog, ready to **import into Jira** (Issue Type / Epic / Story Points / Priority / Labels / AC) |
| [poc-business-case.html](poc-business-case.html) | **Stakeholder pitch deck** — makes the case for the POC and shows the working proof (open in a browser) |
| [dnstap-value-evidence.md](dnstap-value-evidence.md) | **Evidence & findings** — what dnstap adds over native query logging, measured on the lab stack (CPU/event, memory, 60+ fields, bytes/event, 54.7× compression) + exec summary, methodology, caveats |
| [dnstap-collector-sizing.md](dnstap-collector-sizing.md) | **VM sizing** derived from those measurements — CPU/RAM/disk/network, storage-by-retention tables, and three reference builds (POC / production / HA) |
| [../scripts/poc/](../scripts/poc/) | **Interactive test harness** that executes the single-server sequential test — `run_test_dnstap.sh`, `run_test_querylog.sh`, `process_results.py` (see its [README](../scripts/poc/README.md)) |

## Meeting: dnstap → Splunk vs. Infoblox Data Connector → Splunk HEC
| Document | Purpose |
|---|---|
| [meeting-dnstap-vs-dataconnector-hec.md](meeting-dnstap-vs-dataconnector-hec.md) | **Decision brief** — reframes the choice as *in-path vs out-of-band capture* (source), not *scp vs HEC* (transport); steelmans both options, four scenarios, realistic scp→HEC expectations, objections & rebuttals |
| [meeting-slide-outline.md](meeting-slide-outline.md) | **12-slide outline** (~20 min) with speaker notes + backup slides |
| [infoblox-dataconnector-questions.md](infoblox-dataconnector-questions.md) | **12 questions for Infoblox** whose source-mechanism answer (Q1–4) decides the meeting — does the Data Connector source DNS data in-path or off-path? |

## Operations & integration
| Document | Purpose |
|---|---|
| [infoblox-ops-playbook.md](infoblox-ops-playbook.md) | DDI/Ops runbook to enable dnstap on a NIOS member → collector (dry-run → snapshot → apply, validation, rollback, phased rollout) |
| [SNMP-Integration.md](../SNMP-Integration.md) | Design for adding SNMP (host CPU/mem/disk, traps in/out, InfoBlox ibPlatformOne) to the stack |
| [firewall-ports.md](firewall-ports.md) · [ports.md](ports.md) · [ports.csv](ports.csv) | Port/firewall matrix for the pipeline |
| [design.md](design.md) | Pipeline/layering design notes |

## Demo material
| Document | Purpose |
|---|---|
| [demo-presentation.html](demo-presentation.html) | Self-contained demo deck — data flow & component roles |
| [demo-presentation-with-voice.html](demo-presentation-with-voice.html) | Narrated version (browser TTS, speed control, auto-present) |
| [testing-presentation-with-voice.html](testing-presentation-with-voice.html) | **Narrated walkthrough of the evidence test** — single-server method, the M0→M0' run sequence, what's measured, the harness, and the go/no-go. Browser TTS + auto-present, and an **in-browser review/edit mode** (press `E`): edit narration + slide text, auto-saved locally, then **Export edits** (JSON suggestions) or **Export deck** (standalone HTML with edits baked in) |

> Top-level repo docs: `ARCHITECTURE.md`, `QUICKSTART.md`, `CLAUDE.md`.
