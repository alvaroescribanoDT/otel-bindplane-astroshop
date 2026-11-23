# Bindplane processors: what each one is for

A **processor** is a step the collector applies to telemetry *in flight*, between a source and a destination. Nothing here
changes the applications: the shop sends plain OTLP, and Bindplane shapes it on the way to Dynatrace.

The processors are defined in `bindplane/10-processors.yaml` and grouped into five **bundles** in
`bindplane/20-processor-bundles.yaml`, so each source in the Bindplane UI reads as one to three steps. What gets created
depends on `lab.env`:

| Setting | Processors created |
|---|---|
| Always | 23 processors + 5 bundles |
| `ENABLE_S3_ARCHIVE=true` (default) | + `lab-s3-batch` |
| `ENABLE_SERVICE_PREFIX=true` | + the three `lab-prefix-service-name-*` |
| `ENABLE_EKS=true` | + `lab-eks-service-name`, `lab-eks-tag-fields` |

Names here are the template names. In Bindplane each resource is `<LAB_NAME>-<name>` without the `lab-`, `Lab-` or
`otel-` part (e.g. `lab-sample-envoy-ok` becomes `<LAB_NAME>-sample-envoy-ok`), so several labs can share a project.
The impact figures were measured in the original lab and in the package test run (November 2026).

Five jobs, five tags:

| Tag | Job | Question it answers |
|---|---|---|
| `[CUT]` | Remove noise | "Why pay to store this?" |
| `[SAFE]` | Protect data | "What if this leaks?" |
| `[FIX]` | Repair meaning | "Is this data correct and useful?" |
| `[TAG]` | Add context | "Whose data is this, from which host?" |
| `[FIT]` | Make it compatible | "Will Dynatrace accept it?" |

## 1. The pipelines

What each source shows in Bindplane, and what is inside each bundle:

```
SHOP APPS (OTLP)   traces, metrics, logs
 [CUT] drop-failed-flag-evals ─ [FIX] delete-empty-values ─ [TAG] host-detection-light
 ─ bundle Redact-PII ─ [CUT] sample-envoy-ok ─ [FIX] envoy-access-severity ─ [TAG] host-detection-full
 ─ bundle Lab-tags                                                        <- must stay LAST, see section 4
 ──► Dynatrace · Jaeger (traces) · Prometheus (metrics) · S3 archive (logs)

DOCKER LOGS          bundle Docker-Logs                  ──► Dynatrace · OpenSearch · S3 archive
JOURNALD             [FIX] severity-journald ─ [TAG] host-detection-light ─ [TAG] tag-fields-infra
                                                         ──► Dynatrace · OpenSearch · S3 archive
HOST METRICS x3      bundle Host-Metrics (10 s, 5 min, 1 h sources)      ──► Dynatrace
POSTGRES, VALKEY     [TAG] host-detection-light ─ [TAG] tag-fields-infra
                                                         ──► Dynatrace (after cumulative-to-delta) · Prometheus
COLLECTOR ITSELF     bundle Collector-Self-Monitoring    ──► Dynatrace
EKS POD LOGS         [CUT] sample-kafka ─ [FIX] severity-from-message ─ [TAG] eks-service-name ─ [TAG] eks-tag-fields
(optional)                                               ──► Dynatrace

ON THE DYNATRACE DESTINATION (all metrics):  [FIT] cumulative-to-delta
ON THE S3 DESTINATION:                      [FIT] s3-batch (required, see TROUBLESHOOTING.md)
```

## 2. The bundles

| Bundle | Steps, in order | Why it is a bundle |
|---|---|---|
| **Redact-PII** | [SAFE] redact-pii ─ [SAFE] redact-cvv | One "protect the data" step to point at in the demo |
| **Lab-tags** | [TAG] tag-fields ─ optional [TAG] prefix-service-name (logs, metrics, traces) | Naming and tagging of application data, always the last step |
| **Docker-Logs** | [FIX] docker-json-logs ─ **[CUT] drop-unlabelled-docker-logs** ─ [CUT] sample-kafka-logs ─ [FIX] docker-group-by-container ─ [FIX] docker-service-name ─ [FIX] severity-from-message ─ [TAG] host-detection-light ─ [TAG] tag-fields ─ optional [TAG] prefix-service-name-logs | Nine steps for one source. Duplicates are dropped right after parsing (the container name comes from the JSON), so the rest of the chain only sees the ~1% of lines that are kept |
| **Host-Metrics** | [CUT] host-filter-idle ─ [TAG] host-detection-full ─ [FIX] host-transform ─ [CUT] host-filter-delete ─ [FIT] host-cumulative-to-delta ─ [TAG] tag-fields-infra | Dynatrace's host-monitoring recipe, in its required order, used by three sources |
| **Collector-Self-Monitoring** | [TAG] collector-identity-metrics ─ [TAG] collector-identity-logs ─ [TAG] tag-fields-infra | The collector's own telemetry, named so Dynatrace's collector dashboard finds it |

## 3. Every processor, its point and its measured impact

### [CUT] Remove noise
| Processor | What it does | Positive impact (measured) |
|---|---|---|
| `lab-drop-failed-flag-evals` | Drops failed `flagd` evaluations of the two flags missing from the shop's flag file | About 10.7 spans per second (6% of all spans) gone. Failures fell from ~6,600 to ~5 per 10 min. Any other failing flag stays visible, which the incident demo needs. |
| `lab-sample-envoy-ok` | Keeps 1 in 10 envoy access lines for 2xx/3xx; always keeps 4xx, 5xx and disconnects | Overall envoy log volume down ~40-50% (test run: ~2,000 in, ~1,150 out per minute). 4xx/5xx kept with their trace IDs. |
| `lab-sample-kafka-logs` | Keeps 1 in 10 Kafka log lines, but never WARN, ERROR or FATAL (EC2 and EKS) | Kafka lines ~455 to ~45 per 10 min (-90%) on both platforms |
| `lab-drop-unlabelled-docker-logs` | Drops Docker lines from containers without the compose label (the OTel services, which already send logs over OTLP) | Removes ~99% of Docker lines as duplicates (test run: 15,564 per 10 min in, 56 kept) |
| `lab-host-filter-idle` | Drops the "idle" CPU state (Dynatrace's recipe) | Fewer, more useful CPU series |
| `lab-host-filter-delete` | Drops metrics of processes using under 10 MiB (marked by `lab-host-transform`) | 7,154 low-value datapoints removed; keeps process cardinality in check |

Fixed at the source instead of filtered: Postgres used to log `FATAL: role "root" does not exist` every 5 seconds,
because the demo's healthcheck runs `pg_isready` without a user. `shop/compose.override.yaml` now runs
`pg_isready -U postgres`, so the line is never written and no processor is needed.

### [SAFE] Protect data
| Processor | What it does | Positive impact (measured) |
|---|---|---|
| `lab-redact-pii` | Replaces card numbers and emails with a sha3 hash, before any destination | Raw card/CVV/email to 0 (test run: 417 checkout/payment logs in 10 min, 0 raw). The same card gives the same hash: cards can still be counted and followed across checkout and payment. |
| `lab-redact-cvv` | Always masks the CVV (`****`) | A 3-digit CVV is trivially reversible if hashed, so it stays masked |

Caveat: hashing is pseudonymisation. Fine for fake demo data; not for real card numbers without a secret salt.

### [FIX] Repair meaning
| Processor | What it does | Positive impact (measured) |
|---|---|---|
| `delete_empty_values` (inline on the OTLP source) | Removes null, empty and `-` attribute values | Cleaner records, fewer meaningless attributes |
| `lab-docker-json-logs` | Unwraps Docker's JSON lines into a clean message, container name and stream, and gives each record a real event time | Docker logs readable; 8,888 documents had been invisible in OpenSearch (timestamp 1970) |
| `lab-docker-group-by-container` | Regroups records so each container is its own resource | Fixes records attributed to the wrong service |
| `lab-docker-service-name` | Sets `service.name` from the container name | Docker logs show up as `kafka`, `flagd`, ... (with your prefix if enabled) |
| `lab-severity-from-message` | Derives INFO/WARN/ERROR from the message text (Docker, EKS) | EKS: 13.9k lines wrongly `SEVERE` (0 real errors) to all INFO |
| `lab-severity-journald` | Maps the syslog priority to a log level | Journald: all `NONE` to INFO/WARN |
| `lab-envoy-access-severity` | 4xx and status-0 are WARN, 5xx ERROR, the rest INFO | Envoy lines leveled (was all `NONE`); disconnects now WARN |
| `lab-host-transform` | Dynatrace's reshaping for host entities (process attributes, one host-level CPU value) | Needed for host and process entities |

### [TAG] Add context
| Processor | What it does | Positive impact (measured) |
|---|---|---|
| `lab-host-detection-full` | Adds `host.id`, `host.name` (FQDN), OS, CPU and network attributes to metrics and traces | Host and process entities; spans and metrics link to the host |
| `lab-host-detection-light` | Only `host.id` and `host.name`, for logs and the Postgres/Valkey metrics | Logs and database metrics link to the host without the per-container network attributes that triggered ~3,500 "attribute limit" warnings per hour |
| `lab-tag-fields` | Adds environment, `service.namespace` and a Bindplane marker (application data) | 100% of app records tagged |
| `lab-tag-fields-infra` | Environment and marker only (host, journald, Postgres, Valkey, the collector) | Infrastructure data no longer pretends to be a service |
| `lab-collector-identity-metrics` / `-logs` | Names the collector's own telemetry (`service.name`, `service.instance.id`) | Dynatrace's *OpenTelemetry Collector* dashboard shows the collector |
| `lab-prefix-service-name-{logs,traces,metrics}` (optional) | Prefixes every service with your own `SERVICE_PREFIX`, only when `ENABLE_SERVICE_PREFIX=true` | Keeps your services apart from another Astronomy Shop in a shared tenant |
| `lab-eks-tag-fields` (EKS only) | Environment `<EKS_DEPLOYMENT_ENV>` and marker on EKS logs | EC2 and EKS data always separable |
| `lab-eks-service-name` (EKS only) | `service.name = <EKS_SERVICE_PREFIX><container>` | Every EKS log has a service; never merges with EC2 services |

Dynatrace keeps resource attributes such as `host.name` and `deployment.environment` as dimensions on OTLP metrics,
so the Postgres and Valkey metrics stay filterable by host and environment without copying them onto each datapoint.

### [FIT] Make it compatible with Dynatrace
| Processor | What it does | Positive impact (measured) |
|---|---|---|
| `lab-cumulative-to-delta` (on the Dynatrace destination) | Converts running totals to per-interval changes; drops each series' first point | Dynatrace rejects cumulative metrics; now the HTTP histograms and demo counters arrive. `postgresql.commits` no longer spikes (2.9M) after a restart. |
| `lab-host-cumulative-to-delta` | Same for host metrics, with 25 h memory (Dynatrace's recipe) | Hourly series survive |
| `lab-s3-batch` (on the S3 destination) | Batches logs every 10 s | Required: the S3 exporter in this collector version crashes on an empty batch |

## 4. Rules that matter when you change things
- **Order is behaviour.** `lab-sample-envoy-ok` and `lab-envoy-access-severity` match `service.name == "frontend-proxy"`. With the optional prefix on, the `Lab-tags` bundle renames services; if it runs before them, nothing is sampled (log volume doubles) and envoy lines lose their severity. Keep `Lab-tags` last.
- **Drop early.** Filters and samplers belong as early as their condition allows: in `Docker-Logs`, the duplicate drop runs right after parsing, so the other eight steps only see the lines that are kept.
- **Updating a processor** makes Bindplane point every configuration and bundle that uses it at the new version; the change stays pending until a rollout.
- **Keep `lab-s3-batch` on any S3 destination**: the S3 exporter in this collector version crashes on an empty batch.
- **Validate conditions against what the pipeline sees**, not what Dynatrace shows: a Dynatrace field name (for example `log_name`) is not necessarily a pipeline attribute.
