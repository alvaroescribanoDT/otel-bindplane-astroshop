# Troubleshooting and known issues

Most of these were hit while building the lab; the fixes are already in the templates unless stated otherwise.

## Where to look first

| Question | Command |
|---|---|
| Did the host finish booting? | `./lab.sh shell`, then `sudo tail -50 /var/log/cloud-init-output.log` (done when `/var/log/lab-bootstrap-done` exists) |
| Is the collector running? | `sudo systemctl status observiq-otel-collector`; log: `sudo tail -f /opt/observiq-otel-collector/log/collector.log` |
| Is the collector connected and on the latest version? | `bindplane --profile <LAB_NAME> get agents`, `bindplane --profile <LAB_NAME> rollout status <LAB_NAME>-shop-agent` |
| Are the shop containers healthy? | `cd /opt/opentelemetry-demo && sudo docker compose ps` |
| Is everything flowing? | `./lab.sh check` |
| `check` warns that it cannot list S3, or `pii`/`down` fail with `ExpiredToken` | Your AWS session expired: refresh the credentials and run the command again (the Dynatrace checks do not need AWS) |

## Bindplane and the collector

**The S3 destination crashes the collector.** The `awss3` exporter in this collector version (BDOT 1.110.2, contrib
0.162) panics on an empty log batch and the collector crash-loops. The `lab-s3-batch` processor on the S3 destination
prevents it. Keep it on any S3 destination.

**Resource names.** In Bindplane every resource is `<LAB_NAME>-<template name>` (the template's `lab-`/`Lab-`/`otel-`
prefix dropped): `lab-sample-envoy-ok` becomes `<LAB_NAME>-sample-envoy-ok`, `otel-shop-agent` becomes
`<LAB_NAME>-shop-agent`. Export a changed resource under that name and copy the change into the template.

**Processor order is behaviour.** Bundles and processors run top to bottom. `lab-sample-envoy-ok` and
`lab-envoy-access-severity` match `service.name == "frontend-proxy"`; with the optional service prefix on, the `Lab-tags`
bundle renames services, so if it runs before them nothing matches: envoy log volume doubles and its lines lose their
severity. Keep `Lab-tags` last on the OTLP source.

**A bad rollout keeps coming back.** On connect, Bindplane first sends the collector its *current* version and only
then the rollout's new one. If the current version crashes the collector, fixing the configuration is not enough on
its own: roll out the fixed version, then `bindplane rollout update <LAB_NAME>-shop-agent` until the collector reports it.
Wait a few minutes after any rollout and check the collector stays Connected.

**After editing in the Bindplane UI.** The templates in `bindplane/` are the source of truth for `./lab.sh bindplane`.
If you change the configuration in the UI and want to keep it, export it
(`bindplane --profile <LAB_NAME> get configuration <LAB_NAME>-shop-agent -o yaml --export`) and copy the change into the
template. Exports show secrets as `(sensitive)`: the Postgres password must stay
`${env:POSTGRES_MONITORING_PASSWORD}`, and the Dynatrace token placeholder must stay a placeholder.

**Postgres metrics missing.** The collector reads the monitoring password from `/etc/shop-agent.env` (filled at boot
from the demo's `src/postgresql/init.sql`, whose literal differs from the `.env` value). Check that the file exists
and that `/etc/systemd/system/observiq-otel-collector.service.d/lab.conf` loads it.

## Dynatrace

**Metrics rejected (`UNSUPPORTED_METRIC_TYPE_MONOTONIC_CUMULATIVE_SUM`).** Dynatrace accepts delta only. The
`lab-cumulative-to-delta` processor on the Dynatrace destination converts them; Prometheus gets the cumulative values.

**"Partial success: attribute value count is over the allowed amount" on logs.** Full resource detection adds every
network interface (one per container) to each record. Logs therefore use `lab-host-detection-light`
(`host.id` and `host.name` only); the full set stays on metrics and traces.

**No OpenTelemetry host entity.** Install the *OpenTelemetry Host Monitoring* extension from Hub, then
`./lab.sh dynatrace` (or `python3 dynatrace/openpipeline_routes.py status`) to make sure the lab's routes point to
its pipelines. Entities are created at ingest: allow a few minutes.

**The host page's Logs tab is empty.** Known platform gap: the tab uses `dt.log.status_per_entity_count`, which has
no OTel host dimension, so it stays empty even though the logs carry `host.id`/`host.name`. Query the logs instead
(`fetch logs | filter host.name == "<host>"`).

**`dtctl` talks to the wrong tenant.** `lab.sh` always passes `--context $DTCTL_CONTEXT`. When you run `dtctl` by
hand, check `dtctl ctx` first or pass `--context` explicitly.

**Dashboards show empty tiles.** Expected in the first minutes and for the EKS tiles when `ENABLE_EKS=false`.
`python3 dynatrace/build_dashboards.py validate` (with lab.env exported) runs every tile query.

## The shop

**The GenAI `agent` container floods its log with `OSError: [Errno 24] Too many open files`.** It leaks file
descriptors after running for a while (~240 lines/s). Its logs are dropped by the collector (duplicate Docker
stdout), but the chatbot stops answering. Fix: `sudo docker compose restart agent` in `/opt/opentelemetry-demo`.

**Kafka restarts (out of memory).** The broker's memory limit in the full layer is tight under load. If `checkout`
or `accounting` stall, restart `kafka`, then `checkout` and `load-generator`. A higher limit can be set in
`shop/compose.override.yaml` (`kafka: deploy: resources: limits: memory: ...`).

**`frontend-proxy` never starts.** Upstream 3.1.0 bug: the `recommendation` healthcheck uses `nc`, which the image
lacks. `shop/compose.override.yaml` replaces it.

**Postgres logs `FATAL: role "root" does not exist` every 5 seconds.** The demo's healthcheck runs `pg_isready`
without a user. `shop/compose.override.yaml` runs `pg_isready -U postgres` instead; if you still see the line, the host
was built from an older package version (rebuild it, or restart `astronomy-db` with the current override).

**`flagd` evaluations fail for `kafkaConsumerDead` and `cartMetricCardinalityOverflow`.** The two flags are missing
from the demo's flag file. `lab-drop-failed-flag-evals` drops those spans only; any other failing flag is kept for the
incident demo.

**No checkout/payment logs with PII.** The synthetic generator is off by default: `./lab.sh pii status`, then
`./lab.sh pii on`. On a host that is still booting, `pii on` waits for the bootstrap to finish (up to 20 minutes).

**`docker compose` fails with an override error.** With `COMPOSE_FILE` set, run `sudo docker compose config -q` first
to see which file is invalid.
