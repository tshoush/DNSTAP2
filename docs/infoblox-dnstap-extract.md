# InfoBlox DNSTap configuration — extracted from the grid

Pulled live from the Grid Manager WAPI (`192.168.1.224`, `admin`, WAPI **v2.13**)
on 2026-06-26. Covers the two distinct features on **Grid/Member DNS Properties →
Advanced → Logging**: (1) **DNSTAP**, and (2) **Data Collection / Capture DNS
Queries-Responses** — plus the ADP / DNS Cache Acceleration dependency.

> **Two different things on that screen, don't confuse them:**
> 1. **"DNSTAP settings for DNS Queries/Responses"** — streams dnstap frames to an
>    external receiver (our pipeline). Fields: `enable_dnstap_queries`,
>    `enable_dnstap_responses`, `dnstap_setting{receiver_address, receiver_port,
>    identity, version}`. **Gated by ADP/DCA** (see §3).
> 2. **"Data Collection for all DNS Queries/Responses to a Domain"** (Capture DNS
>    Queries/Responses) — a separate, domain-scoped capture-to-file feature, NOT
>    dnstap. Fields: `enable_capture_dns_queries/responses`,
>    `capture_dns_queries_on_all_domains`, `domains_to_capture_dns_queries`,
>    `dns_query_capture_file_time_limit`.

---

## 1. DNSTAP — `grid:dns` and `member:dns`

`dnstap_setting` sub-object: `dnstap_receiver_address` · `dnstap_receiver_port` ·
`dnstap_identity` · `dnstap_version`. `use_dnstap_setting` (member only): true =
member overrides grid; false = inherit grid.

| Scope | use_dnstap_setting | queries | responses | receiver | port | identity |
|---|---|---|---|---|---|---|
| **Grid default** (`grid:dns`) | — | false | false | *(unset)* | 6000 | Infoblox |
| **`.224` GM** (infoblox) | **false** → inherits grid | false | false | *(unset)* | 6000 | Infoblox |
| **`.222`** (infoblox222) | **true** → override | **true** | **true** | **192.168.1.50** | **6001** | Infoblox |

Only `.222` emits dnstap (CLIENT_QUERY + CLIENT_RESPONSE) → `192.168.1.50:6001`.
NIOS exposes only client-side toggles; no RESOLVER_*/auth-side dnstap in this build.

---

## 2. Data Collection / Capture DNS Queries-Responses — `grid:dns`, `member:dns`

The screenshot's lower section. **Disabled everywhere** — unrelated to our feed.

| Scope | use_enable_capture_dns | capture queries | capture responses | all domains | domain list | file time limit |
|---|---|---|---|---|---|---|
| Grid default | — | false | false | false | *(empty)* | 10 min |
| `.224` GM | false → inherit | false | false | false | *(empty)* | 10 |
| `.222` | false → inherit | false | false | false | *(empty)* | 10 |

Member-only extras (unset here): `dns_query_source_address`,
`dns_query_source_interface`, `use_capture_dns_queries_on_all_domains`.

---

## 3. ADP / DCA dependency — why dnstap is OFF at grid/GM but ON at `.222`

The GUI note **"DNSTAP Queries/Responses supports when ADP/DCA is Enabled"** is a
**functional prerequisite**, not a separate field: NIOS only lets you enable
`enable_dnstap_queries/responses` on a member that has **Advanced DNS Protection
(ADP / threat protection)** *or* **DNS Cache Acceleration (DCA)** enabled.
`threatprotection`/`member:dns` carry no dnstap fields themselves — the gate is
enforced by NIOS. The live grid proves it:

| Member | ADP (`member:threatprotection.enable_service`) | DCA (`enable_dns_cache_acceleration`) | DNSTAP allowed? | DNSTAP actually on? |
|---|---|---|---|---|
| **`.222`** infoblox222 | **true** (object exists) | false | **yes** (ADP) | **yes** |
| **`.224`** GM infoblox | *(no threatprotection object)* | false | no | no |
| Grid default | n/a | n/a | n/a | no |

So `.222`'s dnstap works **because ADP is enabled there**. The GM has neither ADP
nor DCA, so its dnstap checkboxes stay unavailable/off (matching the screenshot:
grid Queries/Responses unchecked, receiver address blank, port 6000).
Grid ADP context: `current_ruleset=20260414-14`,
`enable_accel_resp_before_threat_protection=true`.

---

## 4. DNS Cache Acceleration — `member:dns`

DCA is the *other* thing that can gate dnstap. Fields:
`enable_dns_cache_acceleration`, `dns_cache_acceleration_status`,
`dns_cache_acceleration_ttl`, `max_cache_ttl`, `max_ncache_ttl`,
`max_cached_lifetime` (+ `use_*` overrides).

| Member | enable_dns_cache_acceleration | status |
|---|---|---|
| `.224` GM | false | UNKNOWN |
| `.222` | false | UNKNOWN |

**DCA off on both** (UNKNOWN = no accel hardware on these VMs). On `.222` it's ADP,
not DCA, that satisfies the dnstap gate.

---

## 5. TESTED: disabling ADP on `.222` (2026-06-26)

Empirically toggled `member:threatprotection.enable_service` on `.222` (with
dnstap left enabled) and sent live `dig` queries, measuring at the first hop
(`.50:6001` dnscollector `operations_total`) and end-to-end into Splunk
(`index=mi_dhcp`). **Reproducible in both directions:**

| State | `CLIENT_QUERY` Δ (20 digs) | `CLIENT_RESPONSE` Δ | Splunk events |
|---|---|---|---|
| **ADP ON** | **+20** | +20 | 20 query-lines + 20 response-lines |
| **ADP OFF** | **+0 (stops)** | +20 (continues) | 0 query-lines + 20 response-lines |

First reading (via DNS-collector `:6001`): "ADP gates the query stream" — with
ADP off, `CLIENT_QUERY` appeared to stop while `CLIENT_RESPONSE` continued. **This
turned out to be a DNS-collector path artifact, not an InfoBlox/ADP behavior — see
§5a.**

### 5a. Re-test via Vector `:6000` direct — corrects the conclusion

Repointed `.222` dnstap to `:6000` (Vector, no DNS-collector in the path) and
repeated ADP on → off → on. Measured Vector intake + Splunk query/response lines:

| Phase | ADP | Vector `dnstap_in` Δ | Splunk query-lines | response-lines |
|---|---|---|---|---|
| A | ON | 40 | 20 | 20 |
| B | **OFF** | 40 | **20** | 20 |
| C | ON | 40 | 20 | 20 |

**On Vector `:6000`, ADP makes NO difference — both CLIENT_QUERY and
CLIENT_RESPONSE flow whether ADP is on or off.** Same member, same toggle; the
only change was the receiver.

**Corrected conclusion:**
- **InfoBlox emits CLIENT_QUERY dnstap regardless of ADP/DCA.** ADP is NOT
  required for the query stream.
- The earlier "queries stop without ADP" was an artifact of the **DNS-collector**
  path — most likely its `latency` transform (`measure-latency` +
  `unanswered-queries`) pairing each query with its response and collapsing the
  standalone query event when ADP changes query→response timing. Vector does no
  such pairing, so the raw stream (queries + responses) always passes through.
- Practical takeaway: **Vector `:6000` is the more faithful dnstap path** — it
  preserves the full stream independent of ADP. (The GUI's "supports when ADP/DCA
  is Enabled" is about being allowed to *enable* the dnstap checkboxes, not about
  runtime emission.)

Restored `.222` ADP to `enable_service=true` after testing; `.222` left pointed at
`:6000` (Vector). Both streams flowing.

---

## Summary

- **DNSTAP** is enabled only on **`.222`** via a member override. It is now
  pointed at **`192.168.1.50:6000` (Vector)**, identity `Infoblox`, queries +
  responses. (Originally `:6001`/DNS-collector; switched to Vector — the more
  faithful path, see §5a.)
- ADP/DCA is required only to **enable** the dnstap checkboxes in the GUI, not for
  runtime emission. The GM `.224` has no ADP/DCA, so its dnstap is
  unavailable/off (the grid-level screenshot is blank for that reason).
- **DCA** is off on both members; **ADP** is on for `.222` (ruleset
  `20260414-14`) but does not affect what dnstap emits (§5a).
- **Data Collection / Capture DNS Queries-Responses** (the lower section) is a
  separate file-capture feature and is **off everywhere** — not part of the
  dnstap → Splunk pipeline.
