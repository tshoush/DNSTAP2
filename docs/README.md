# DNSTAP2 — Documentation Index

## POC decision: native DNS query logging vs. dnstap
| Document | Purpose |
|---|---|
| [poc-evaluation-plan.md](poc-evaluation-plan.md) | The decision plan — weighted scorecard, 11 technical tests, cost (3-yr TCO) & implementation analysis, risks, go/no-go framework |
| [jira-stories.md](jira-stories.md) | Execution backlog — 6 epics, 19 stories (62 pts) with acceptance criteria |
| [jira-stories.csv](jira-stories.csv) | The same backlog, ready to **import into Jira** (Issue Type / Epic / Story Points / Priority / Labels / AC) |
| [poc-business-case.html](poc-business-case.html) | **Stakeholder pitch deck** — makes the case for the POC and shows the working proof (open in a browser) |

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

> Top-level repo docs: `ARCHITECTURE.md`, `QUICKSTART.md`, `CLAUDE.md`.
