# Observability & Reliability Design

**Scope:** the Section 3 application — **frontend on AWS EKS**, **backend API on Azure AKS**, **PostgreSQL on Azure** — connected privately across clouds. It currently has no observability and suffers **latency spikes and intermittent failures**.
**Deliverables:** this document and [`alerts.yaml`](alerts.yaml) (validated with `promtool check rules`, unit-tested with [`alerts_test.yaml`](alerts_test.yaml)).

---

## 1. Approach

Start from what users experience, define SLOs for it, and derive dashboards and alerts from those SLOs. Alerts page a human only for **user-visible symptoms**; causes (tunnel down, DNS errors, DB connections) are dashboards, warnings and tickets that explain the symptom.

| SLO (per user-facing service: `frontend`, `backend-api`) | Target (30-day window) | Error budget |
| --- | --- | --- |
| **Availability**: non-5xx responses / all responses | 99.9 % | 0.1 % ≈ 43 min of full outage per month |
| **Latency**: requests served in < 300 ms / all requests | 99 % | 1 % of requests may be slower |

The error budget is the decision tool: while budget remains, ship features; when it is exhausted, reliability work takes priority. The budget-erosion alert (ticket) triggers that conversation.

## 2. Tooling choice

**OpenTelemetry** for instrumentation and collection, with a vendor-neutral **Grafana stack** backend:

| Signal | Store | Why |
| --- | --- | --- |
| Metrics | Prometheus (per cluster) → **Mimir** (central, long-term) | PromQL, native histograms, one query surface across both clouds |
| Logs | **Loki** | Label-indexed, cheap object-storage backend, LogQL shares labels with metrics |
| Traces | **Tempo** | Trace-by-ID from logs, exemplars from metrics |
| Alerting | Prometheus rules + **Alertmanager** → PagerDuty (page) / Slack (warning) / Jira (ticket) | Rules as code, reviewed in PRs |
| Dashboards | **Grafana** | One UI for all three signals, dashboards as JSON in git |

**Why not the cloud-native tools?** The app spans AWS and Azure; CloudWatch and Azure Monitor each see half of a request. A single OpenTelemetry pipeline gives one trace across the cloud boundary and one set of labels everywhere. Cloud-native metrics (VPN tunnels, managed PostgreSQL, load balancers) are **pulled into** the same store via the CloudWatch exporter and the collector's Azure Monitor receiver. The stack is open source and can run self-hosted or as Grafana Cloud; the design does not depend on which.

## 3. Instrumentation

```
 EKS cluster                                   AKS cluster
 ┌──────────────────────────┐                  ┌──────────────────────────┐
 │ frontend (OTel SDK)      │ ── traceparent ─▶│ backend-api (OTel SDK)   │──▶ PostgreSQL
 │ OTel Collector DaemonSet │                  │ OTel Collector DaemonSet │
 │  (node, kubelet, logs)   │                  │  (node, kubelet, logs)   │
 │ Collector gateway ───────┼──┐           ┌───┼─ Collector gateway       │
 └──────────────────────────┘  │  private  │   └──────────────────────────┘
   CloudWatch exporter (VPN)   ▼  link     ▼    Azure Monitor receiver (PG, VPN GW)
                         Mimir · Loki · Tempo · Grafana · Alertmanager
```

- **Application**: OpenTelemetry SDK with auto-instrumentation for HTTP server/client and the PostgreSQL driver. Emits the semantic-convention histogram `http_server_request_duration_seconds` with `http_route` and `http_response_status_code`; histogram boundaries include **0.3 s and 1 s** so SLO thresholds are exact, not interpolated. The W3C `traceparent` header is propagated frontend → backend → DB spans, so a single trace crosses the cloud boundary.
- **Collector DaemonSet** per node: container logs, kubelet/cAdvisor metrics, host metrics. **Collector gateway** per cluster: batching, attribute enrichment (`cluster`, `cloud`, `region`, `service`), PII redaction, **tail-based sampling** (keep 100 % of error and slow traces, 10 % of the rest).
- **kube-state-metrics**, **CoreDNS** and **postgres_exporter** metrics are scraped by the same Prometheus.
- **Synthetic probes** (Blackbox exporter) run **from both clouds**: the user journey (`/health` and one read endpoint), and a **cross-cloud probe** from EKS to the backend's internal hostname, which isolates the VPN/DNS path from application behaviour.
- Telemetry travels over the same private connectivity as the application (Section 3); no telemetry endpoint is public.

## 4. Metrics: the four golden signals

| Signal | Definition (PromQL, per service) | Where it shows |
| --- | --- | --- |
| **Request rate** | `sum by (service) (rate(http_server_request_duration_seconds_count[5m]))` | All dashboards; drops reveal upstream outages |
| **Error rate** | 5xx / all requests: `service:http_errors:ratio_rate5m` (recording rule) | SLO, alerts |
| **Latency** | p50/p95/p99 from the histogram: `service:http_latency:p95_5m`; share over 300 ms: `service:http_slow:ratio_rate5m` | SLO, alerts, heatmap |
| **Saturation** | CPU/memory vs. requests and limits, CPU throttling, HPA at max replicas, pod restarts, **PostgreSQL connections / max**, DB CPU & IOPS, **VPN tunnel throughput vs. capacity** | Infrastructure dashboard, warnings |

Specific signals for the reported **latency spikes and intermittent failures**, which point at the cross-cloud hop and the database:

- VPN tunnel state and bytes per tunnel (asymmetric traffic after a tunnel flap is a classic spike cause).
- DNS: CoreDNS SERVFAIL/timeout ratio and resolution latency (private DNS forwarding across clouds).
- Cross-cloud synthetic probe latency (baseline ~20–40 ms; spikes isolate the network path).
- PostgreSQL: connection-pool wait time, active vs. max connections, slow queries (`pg_stat_statements`), locks, replication lag.
- Client-side timeouts and retries on the frontend's calls to the backend (a retry storm makes a spike worse).

## 5. Dashboards

### 5.1 Executive service health (management KPIs)

One page, no infrastructure detail, green/amber/red.

- SLO attainment (30 days) and **remaining error budget** per service (availability and latency)
- Availability % and p95 latency, trend over 30 days with the SLO line
- Request volume (business activity), week over week
- Incidents this month, **MTTR** and MTTD, and deploy count (change-failure context)
- Current open alerts at page severity

### 5.2 Application observability (for on-call and developers)

- **RED per service and per route**: rate, error ratio, latency p50/p95/p99
- Latency **heatmap** (spikes are visible as bands) with **exemplars** linking to traces
- Errors by status code and by exception type (from logs)
- Service dependency map generated from traces (frontend → backend → PostgreSQL)
- Top slow endpoints and slow DB queries
- **Deploy markers** (annotations from the CD pipeline) on every panel, to correlate regressions with releases
- Burn-rate panel per SLO

### 5.3 Infrastructure observability (for the platform team)

- Per cluster (EKS, AKS): node CPU/memory, pod restarts, CPU throttling, pending pods, HPA current vs. max
- **Cross-cloud path**: VPN tunnel state and throughput per tunnel, cross-cloud probe latency, packet loss
- **DNS**: query rate, SERVFAIL ratio, latency per resolver and forwarding rule
- **PostgreSQL**: CPU, memory, IOPS, storage, connections vs. max, replication lag, deadlocks
- Load balancers: healthy targets, 5xx at the LB vs. at the app (separates platform from app failures)

## 6. Logging

**Format**: structured JSON, one event per line, UTC timestamps. The demo app in this repo already logs this way.

| Field | Example | Notes |
| --- | --- | --- |
| `timestamp` | `2026-09-25T22:19:58.219Z` | ISO-8601 UTC |
| `level` | `INFO`, `WARN`, `ERROR` | `DEBUG` off in prod, sampled when enabled |
| `service`, `version`, `env` | `backend-api`, git SHA, `prod` | Set once by the logger |
| `cluster`, `cloud`, `region` | `aks-prod`, `azure`, `germanywestcentral` | Added by the collector |
| `trace_id`, `span_id` | W3C ids | Injected from the active span: log → trace in one click |
| `request_id` | `X-Request-ID` value | Generated at the edge if missing, propagated to every service |
| `http.method`, `http.route`, `http.status`, `duration_ms` | `GET`, `/orders/{id}`, `200`, `42` | Route template, not raw path (bounded cardinality) |
| `user_id` | hashed | Never raw PII |
| `message`, `error.type`, `error.stack` | | Stack only on `ERROR` |

**Correlation IDs.** The edge (ingress/load balancer) sets `X-Request-ID` if absent; every service propagates it and `traceparent` on outgoing calls; the logger adds `trace_id` automatically. One ID therefore joins the frontend log line, the backend log line, the DB span and the trace.

**Rules.** No secrets, tokens, passwords or raw PII in logs; the collector redacts known patterns as a backstop. Logs are labelled only by low-cardinality keys (`service`, `cluster`, `level`); IDs stay in the log body.

**Retention.**

| Class | Hot (searchable) | Archive | Why |
| --- | --- | --- | --- |
| Application logs | 14 days | 90 days (object storage) | Incident investigation and comparison with last release |
| Audit / security logs | 90 days | 1 year+ | Compliance, forensics |
| Debug logs | 3 days | none | Volume control |
| Metrics | 15 days raw | 13 months downsampled | Year-over-year capacity and SLO trends |
| Traces | 7 days | none | Tail-sampled; exemplars cover the long tail |

## 7. Alerts

Defined in [`alerts.yaml`](alerts.yaml) as Prometheus rules. Every alert carries `severity`, `team`, a summary with the current value, and a `runbook_url`.

| Alert | Condition | Severity |
| --- | --- | --- |
| `AvailabilitySLOFastBurn` | error ratio > 14.4 × budget over **1 h and 5 m** (2 % of the monthly budget per hour) | page |
| `AvailabilitySLOSlowBurn` | > 6 × budget over **6 h and 30 m** | page |
| `AvailabilitySLOBudgetErosion` | > 1 × budget over 3 d and 6 h | ticket |
| `EndpointDownFromBothClouds` | synthetic user journey failing from **every** probe location for 3 min | page |
| `LatencySLOBurn` | share of requests > 300 ms burning the latency budget 14.4 × | page |
| `HighP99Latency` / `ElevatedP95Latency` | p99 > 1 s for 5 m / p95 > 300 ms for 10 m | page / warning |
| `HighErrorRate` | 5xx > 2 % for 5 m with > 1 req/s | page |
| `VpnTunnelDown` / `AllVpnTunnelsDown` | one tunnel down 5 m / all tunnels down 2 m | warning / page |
| `CrossCloudPathSlow`, `DnsResolutionFailures`, `PostgresConnectionsNearLimit`, `PodCrashLooping`, `HpaAtMaxReplicas` | cause-oriented | warning |

Design choices:

- **Multi-window burn rates** (from the Google SRE workbook) page quickly for real incidents and stay quiet for short blips; the short window makes alerts resolve soon after recovery.
- **Symptoms page, causes warn.** A single VPN tunnel down is redundancy loss, not an outage; all tunnels down is an outage.
- **Synthetic probes from both clouds** catch total outages where request-based SLIs go silent (no traffic reaches the app at all).
- **Traffic floor** on the error-rate alert avoids paging on one failed request at night.
- Alertmanager **groups** by `service` and **inhibits** cause alerts while `AllVpnTunnelsDown` fires, so on-call gets one page, not twenty.
- `promtool test rules docs/alerts_test.yaml` proves that a 5 % error ratio fires `HighErrorRate` and the fast burn, that healthy traffic fires nothing, and that a probe failing from both clouds pages.

## 8. Runbooks

### Runbook: availability

1. Executive dashboard: which service, since when, how much budget is gone.
2. Application dashboard: errors on all routes (platform) or one route (code)? Check the **deploy markers**; if a release lines up, roll back first, investigate second.
3. Compare 5xx at the load balancer vs. the app: LB-only 5xx means no healthy backends (pods, probes, network).
4. Follow an exemplar into a failing trace to find the failing hop.

### Runbook: latency

1. Heatmap: is the whole distribution shifted (saturation) or a band of slow requests (one dependency)?
2. Trace exemplars: which span dominates — frontend→backend (network), backend handler (code/CPU), or DB?
3. DB: connection-pool wait, active connections vs. max, slow queries, locks.
4. Saturation: CPU throttling, HPA at max, node pressure. Scale out if needed, then find the cause.

### Runbook: errors

1. Error breakdown by status and exception type; open matching logs via `trace_id`.
2. `PodCrashLooping`? Check recent config/secret changes and the last deploy.
3. Upstream 502/504 from the frontend usually means the backend or the cross-cloud path; continue with the cross-cloud runbook.

### Runbook: cross-cloud

1. Tunnel state per tunnel; if one is down, confirm traffic has failed over (throughput on the remaining tunnels).
2. Cross-cloud probe latency vs. baseline; packet loss.
3. DNS: SERVFAIL ratio and resolver latency; test resolution of the backend's private name from an EKS pod.
4. Escalate to the network owner with the probe and tunnel graphs attached.

## 9. Risk management and rollout

| Risk | Mitigation |
| --- | --- |
| Alert fatigue | Page only on SLO symptoms; review every page weekly; delete alerts nobody acted on |
| Telemetry cost explosion | Tail sampling, bounded label cardinality (route templates), log levels, retention tiers, budget alerts on the observability stack itself |
| Observability outage hides a real outage | Meta-monitoring: dead-man's-switch alert (`Watchdog`) to an external heartbeat service |
| Cross-cloud telemetry path fails with the app | Collectors buffer to disk and retry; synthetic probes alert from outside the failing path |

**Rollout (first 6 weeks):** (1) instrument both services and deploy collectors; (2) collect two weeks of baseline and set SLO targets from real data; (3) enable dashboards and burn-rate alerts in *warning-only* mode; (4) tune thresholds, then enable paging; (5) run a game day — fail a VPN tunnel and slow the DB — and confirm the right alerts fire and the runbooks work.