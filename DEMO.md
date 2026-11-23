# Demo script (30-40 minutes)

Replace `<ENV>` with your `DEPLOYMENT_ENV`, and `<P>` with your `SERVICE_PREFIX` if you turned the optional prefix on
(otherwise drop `<P>`: the services keep their own names, e.g. `checkout`). `./lab.sh info` prints the URLs.
## Before the demo

```bash
./lab.sh pii on      # at least 15 minutes before: fake checkout/payment logs with card numbers and emails
./lab.sh check       # everything green, including "PII: ... 0 raw card numbers or emails"
```

Start the lab itself at least 30 minutes before so there is history to show. After the demo: `./lab.sh pii off`
(and turn the `emitRawPii` flag off if you used it).

## 0. Set the scene (Bindplane UI, 3 min)

Open the configuration **`<LAB_NAME>-shop-agent`** in Bindplane (all lab resources are named `<LAB_NAME>-…`).

- One collector on the shop host, managed remotely: no config files on the machine.
- Each source shows one to three steps: most of the work is grouped into bundles (`Host-Metrics`,
  `Docker-Logs`, `Redact-PII`, `Lab-tags`, `Collector-Self-Monitoring`). Click a bundle to open it.
- Sources on the left: the shop's OTLP, host metrics (Dynatrace's recipe at 10 s / 5 min / 1 h), journald, Docker
  logs, Postgres, Valkey, the collector's own telemetry.
- Destinations on the right: Dynatrace, plus Jaeger, Prometheus, OpenSearch and S3. Same data, many backends, one
  place to change it.
- Every change is versioned and rolled out; show the version history.

## 1. PII never leaves the host (8 min)

With `./lab.sh pii on`, a synthetic generator sends checkout and payment logs with card numbers, CVVs and
customer emails, about 4 orders per minute, through the same collector as the shop (records carry
`lab.synthetic=true`). The shop itself never logs PII, so without the generator there is nothing to redact in logs.

1. In Bindplane, open the **Redact-PII** bundle on the OTLP source: card and email values are **hashed**, the CVV
   is **masked** by key.
2. In Dynatrace (Logs or a Notebook):
   ```
   fetch logs
   | filter deployment.environment == "<ENV>" and in(service.name, array("<P>checkout", "<P>payment"))
   | fields timestamp, service.name, content, demo.payment.card_number, demo.payment.card_cvv, user.email
   ```
   Card numbers and emails are 64-character hashes, CVV is `****`.
3. Point out that **hashing keeps analytics**: the same card gives the same hash, so you can still count customers
   or follow one card across services:
   ```
   fetch logs
   | filter deployment.environment == "<ENV>" and in(service.name, array("<P>checkout", "<P>payment"))
       and isNotNull(demo.payment.card_number)
   | summarize orders = count(), services = countDistinct(service.name), by: {demo.payment.card_number}
   | sort orders desc
   ```
4. Spans too: in the shop's flag UI (`/feature/`) turn **emitRawPii** on. Checkout and payment spans gain the same
   fields, and they arrive hashed and masked as well. Turn it off afterwards.
5. If S3 is enabled: the archive holds the same redacted logs (`aws s3 ls s3://<bucket>/shop-logs/ --recursive`).
   Redaction happens before every destination.

## 2. Less noise, lower cost (8 min)

1. Bindplane shows throughput per processor on the configuration page. Point at:
   - `lab-sample-envoy-ok`: the front proxy's successful access lines, kept 1 in 10; 4xx, 5xx and disconnects
     are always kept. Overall envoy log volume drops by about half.
   - `lab-drop-unlabelled-docker-logs` (first step after parsing in the `Docker-Logs` bundle): the services' stdout is a duplicate of the OTLP logs they already send, so
     only containers without OTLP logs (Kafka, Postgres, Valkey, flagd, envoy) are collected from Docker.
   - `lab-sample-kafka-logs`: 1 in 10 Kafka lines, never WARN/ERROR/FATAL.
   - `lab-drop-failed-flag-evals`: drops failed evaluations of two flags the shop's flag file does not define.
2. The same numbers in Dynatrace, from the collector's own metrics:
   ```
   timeseries in = sum(otelcol_processor_incoming_items), out = sum(otelcol_processor_outgoing_items),
     by: {processor}, filter: otel.signal == "logs"
   | fieldsAdd in = arraySum(in), out = arraySum(out)
   | fieldsAdd dropped_pct = round(100.0 * (in - out) / in, decimals: 1)
   | filter dropped_pct > 0
   ```
3. Dashboard **`<LAB_NAME>` | 2. Bindplane value** summarises it.

## 3. Logs with meaning (4 min)

```
fetch logs
| filter deployment.environment == "<ENV>" and service.name == "<P>frontend-proxy"
| summarize lines = count(), by: {loglevel}
```

Envoy access lines arrive with a level (4xx and disconnects WARN, 5xx ERROR) instead of `NONE`, so Dynatrace can
alert on them. The same idea applies to journald (syslog priority) and Docker logs (level words in the message).

## 4. Hosts, processes and collector health (6 min)

1. **Infrastructure & Operations > OpenTelemetry hosts**: the shop host with its processes, CPU, memory, disk and
   network, built from Dynatrace's host-monitoring recipe running inside the Bindplane collector. Services run on
   the host.
2. The host page's **Logs** tab stays empty (a current platform gap, see TROUBLESHOOTING.md). Show the host's logs
   with a query instead:
   ```
   fetch logs | filter host.name == "<shop host name from ./lab.sh info>" | summarize count(), by: {service.name}
   ```
3. Collector health: Dynatrace's **OpenTelemetry Collector** dashboard (Dashboards > search "collector"). The
   collector sends its own metrics as `<P>bindplane-collector`: accepted vs refused items, queue size, exporter
   failures.

## 5. Break something (6 min)

Dashboard **`<LAB_NAME>` | 3. GenAI, feature flags and incidents**.

1. In `/feature/`, turn on **productCatalogFailure** (or **cartFailure**, **paymentFailure**).
2. Failures appear on the dashboard and as Davis problems within a few minutes. The envoy 5xx lines are kept by the
   sampler (only successes are sampled), so the logs tell the same story as the traces.
3. Optional: chat with the GenAI agent at `/chatbot/` and show its LLM and tool spans (responses are replayed
   from recordings, no LLM key needed).
4. Turn the flag off.

## 6. Wrap-up

- Nothing in the shop was changed for any of this: it sends plain OTLP.
- Everything shown is configuration in Bindplane, versioned and rolled out centrally, and portable to any backend.
- Dynatrace receives cleaner, cheaper, safer data with the context it needs for entities and problems.
