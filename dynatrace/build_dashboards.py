#!/usr/bin/env python3
"""Generates the three lab dashboards, validates their tile queries and deploys them with dtctl.

    build_dashboards.py build      write .build/dynatrace/dashboard-*.json
    build_dashboards.py validate   run every tile query over the last 2 h (expect EMPTY tiles in a fresh lab)
    build_dashboards.py deploy     build, then create or update the dashboards in the tenant

Tile queries contain no time range: the dashboard time picker supplies it. Values come from the environment
(lab.sh exports lab.env): DTCTL_CONTEXT, LAB_NAME, SERVICE_PREFIX, DEPLOYMENT_ENV, EKS_DEPLOYMENT_ENV,
EKS_CLUSTER_NAME, SHOP_URL, SHOP_HOST_NAME. Deploying again updates the dashboards with the same name in place.
"""
import datetime
import json
import os
import subprocess
import sys

CONTEXT = os.environ.get("DTCTL_CONTEXT", "")
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".build", "dynatrace")
TOKENS = ["LAB_NAME", "SERVICE_PREFIX", "DEPLOYMENT_ENV", "EKS_DEPLOYMENT_ENV", "EKS_CLUSTER_NAME", "SHOP_URL",
          "SHOP_HOST_NAME"]

# "Ours" is the deployment.environment set in lab.env; it works with or without the optional service-name prefix.
OURS = 'deployment.environment == "__DEPLOYMENT_ENV__"'
PREFIXED = bool(os.environ.get("SERVICE_PREFIX"))
BASE = 'replaceString(service.name, "__SERVICE_PREFIX__", "")' if PREFIXED else "service.name"
ENVS = 'in(deployment.environment, {"__DEPLOYMENT_ENV__", "__EKS_DEPLOYMENT_ENV__"})'
HOST = '"__SHOP_HOST_NAME__"'
ROOT = 'request.is_root_span == true'


def md(text):
    return {"type": "markdown", "content": text}


def data(title, query, viz, desc=None):
    t = {"type": "data", "title": title, "query": query, "visualization": viz,
         "visualizationSettings": {}, "querySettings": {}}
    if desc:
        t["description"] = desc
    return t


def single(title, query, desc=None):
    return data(title, query, "singleValue", desc)


# --------------------------------------------------------------------------------------------
# Dashboard 1: demo overview
# --------------------------------------------------------------------------------------------
D1_HEADER = """# __LAB_NAME__: OpenTelemetry + Bindplane + Dynatrace

**One demo, two platforms.** The OpenTelemetry *Astronomy Shop* runs on **EC2** (Docker Compose, with Kafka, accounting, fraud-detection and a GenAI agent/chatbot) and optionally on **EKS** (pod logs only). Everything is collected by **Bindplane-managed collectors** and sent to Dynatrace as pure OTLP.

`EC2 services + host + databases ──► Bindplane collector ──►`  **Dynatrace**  `◄── Bindplane node agent ◄── EKS pod logs`

""" + ("Our services are named `__SERVICE_PREFIX__*` and tagged " if PREFIXED else "Our data is tagged ") + """`deployment.environment` = `__DEPLOYMENT_ENV__` (EC2) / `__EKS_DEPLOYMENT_ENV__` (EKS). Companion dashboards: *2. Bindplane value* and *3. GenAI, feature flags and incidents*. Shop: __SHOP_URL__"""

D1 = [
    ("header", md(D1_HEADER), dict(x=0, y=0, w=24, h=5)),
    ("k_req", single("Requests", f'fetch spans | filter {OURS} and {ROOT} and service.name != "__SERVICE_PREFIX__flagd" | summarize requests = count()',
                     "Root spans of this lab's services (flagd excluded: see the Bindplane value dashboard)"), dict(x=0, y=5, w=4, h=3)),
    ("k_fail", single("Failed requests (%)", f'fetch spans | filter {OURS} and {ROOT} and service.name != "__SERVICE_PREFIX__flagd" | summarize total = count(), failed = countIf(request.is_failed == true) | fieldsAdd failure_pct = round(if(total > 0, failed * 100.0 / total, else: 0.0), decimals: 2) | fields failure_pct'), dict(x=4, y=5, w=4, h=3)),
    ("k_svc", single("Services reporting", f'fetch spans | filter {OURS} | summarize services = countDistinct(service.name)'), dict(x=8, y=5, w=4, h=3)),
    ("k_logs", single("Log records (EC2 + EKS)", f'fetch logs | filter {ENVS} | summarize logs = count()'), dict(x=12, y=5, w=4, h=3)),
    ("k_pods", single("EKS pods logging", 'fetch logs | filter k8s.cluster.name == "__EKS_CLUSTER_NAME__" | summarize pods = countDistinct(k8s.pod.name)'), dict(x=16, y=5, w=4, h=3)),
    ("k_genai", single("GenAI chat calls", 'fetch spans | filter gen_ai.operation.name == "chat" | summarize chats = count()'), dict(x=20, y=5, w=4, h=3)),
    ("rps", data("Requests per minute by service", f'fetch spans | filter {OURS} and {ROOT} and service.name != "__SERVICE_PREFIX__flagd" | makeTimeseries requests = count(), interval: 1m, by: {{service.name}}', "lineChart"), dict(x=0, y=8, w=12, h=8)),
    ("p95", data("p95 latency by service", f'fetch spans | filter {OURS} and {ROOT} and service.name != "__SERVICE_PREFIX__flagd" | makeTimeseries p95 = percentile(duration, 95), interval: 1m, by: {{service.name}}', "lineChart"), dict(x=12, y=8, w=12, h=8)),
    ("failpct", data("Failure rate by service (%), flagd excluded", f'fetch spans | filter {OURS} and {ROOT} and service.name != "__SERVICE_PREFIX__flagd" | summarize total = count(), failed = countIf(request.is_failed == true), by: {{service.name}} | fieldsAdd failure_pct = round(failed * 100.0 / total, decimals: 2) | sort failure_pct desc | limit 10 | fields service.name, failure_pct', "categoricalBarChart"), dict(x=0, y=16, w=12, h=7)),
    ("slow", data("Slowest operations (p95)", f'fetch spans | filter {OURS} and {ROOT} and service.name != "__SERVICE_PREFIX__flagd" | summarize requests = count(), p95_ms = round(percentile(duration, 95) / 1ms, decimals: 1), by: {{service.name, span.name}} | sort p95_ms desc | limit 10', "table"), dict(x=12, y=16, w=12, h=7)),
    ("logs_env", data("Logs per minute by platform", f'fetch logs | filter {ENVS} | makeTimeseries logs = count(), interval: 1m, by: {{deployment.environment}}', "areaChart"), dict(x=0, y=23, w=12, h=7)),
    ("logs_src", data("Top log sources", f'fetch logs | filter {ENVS} | fieldsAdd source = concat(if(deployment.environment == "__EKS_DEPLOYMENT_ENV__", "EKS", else: "EC2"), " / ", coalesce(k8s.container.name, service.name, "host")) | summarize logs = count(), by: {{source}} | sort logs desc | limit 12', "categoricalBarChart"), dict(x=12, y=23, w=12, h=7)),
    ("cpu", data("Shop host CPU utilization", f'timeseries cpu = avg(system.cpu.utilization), by: {{host.name}} | filter host.name == {HOST}', "lineChart"), dict(x=0, y=30, w=6, h=6)),
    ("mem", data("Shop host memory used", f'timeseries used = avg(system.memory.utilization), by: {{host.name, state}} | filter host.name == {HOST} and state == "used"', "lineChart"), dict(x=6, y=30, w=6, h=6)),
    ("pg", data("Postgres commits", 'timeseries commits = sum(postgresql.commits)', "lineChart"), dict(x=12, y=30, w=6, h=6)),
    ("valkey", data("Valkey connected clients", 'timeseries clients = avg(redis.clients.connected)', "lineChart"), dict(x=18, y=30, w=6, h=6)),
]

# --------------------------------------------------------------------------------------------
# Dashboard 2: Bindplane value
# --------------------------------------------------------------------------------------------
D2_HEADER = """# What Bindplane adds

A Bindplane collector on the **EC2 shop host** feeds this tenant (host metrics, journald, Postgres, Valkey, Docker logs *and* the shop's OTLP), plus an optional **node agent on EKS** (pod logs). Bindplane is the control plane only: configuration, rollouts and fleet health. The data goes collector to Dynatrace.

| Without Bindplane | With Bindplane (this lab) |
|---|---|
| Every collector config hand-edited per host | One configuration per platform, rolled out centrally and versioned |
| The shop's `frontend` collides with other teams' `frontend` in a shared tenant | """ + ("`__SERVICE_PREFIX__` service prefix and tags" if PREFIXED else "Environment and namespace tags (optional service prefix)") + """ applied in the pipeline, no app change |
| Cumulative counters and histograms are rejected by Dynatrace | Converted to delta in flight, so the metrics arrive |
| Raw container logs, no context | Kubernetes and host context added, duplicates dropped |
| Noise goes straight to Grail | Noise is visible here and can be filtered or sampled at the collector |"""

D2 = [
    ("header", md(D2_HEADER), dict(x=0, y=0, w=24, h=8)),
    ("flow_spans", data("Spans through the EC2 collector (per minute)", f'fetch spans | filter {OURS} | makeTimeseries spans = count(), interval: 1m', "areaChart"), dict(x=0, y=8, w=12, h=7)),
    ("flow_logs", data("Logs through the collectors, EC2 vs EKS (per minute)", f'fetch logs | filter {ENVS} | makeTimeseries logs = count(), interval: 1m, by: {{deployment.environment}}', "areaChart"), dict(x=12, y=8, w=12, h=7)),
    ("cov_spans", data("Enrichment coverage: spans", f'fetch spans | filter {OURS} | summarize records = count(), processed_by_bindplane_pct = round(countIf(lab.processed_by == "bindplane") * 100.0 / count(), decimals: 1), with_host_id_pct = round(countIf(isNotNull(host.id)) * 100.0 / count(), decimals: 1), with_environment_pct = round(countIf(isNotNull(deployment.environment)) * 100.0 / count(), decimals: 1)', "table",
                       "Tags added by Bindplane processors. Should be close to 100%; a lower value usually means data from outside this lab matched the filter."), dict(x=0, y=15, w=12, h=5)),
    ("cov_logs", data("Enrichment coverage: logs per platform", f'fetch logs | filter {ENVS} | summarize records = count(), processed_by_bindplane_pct = round(countIf(lab.processed_by == "bindplane") * 100.0 / count(), decimals: 1), with_host_id_pct = round(countIf(isNotNull(host.id)) * 100.0 / count(), decimals: 1), with_k8s_cluster_pct = round(countIf(isNotNull(k8s.cluster.name)) * 100.0 / count(), decimals: 1), by: {{deployment.environment}}', "table"), dict(x=12, y=15, w=12, h=5)),
    ("shared", data("Shared tenant: our spans vs everyone else's", f'fetch spans | filter isNotNull(service.name) | summarize spans = count(), by: {{owner = if({OURS}, "this lab", else: "everything else in the tenant")}}', "donutChart"), dict(x=0, y=20, w=8, h=7)),
    ("clash", data("Same service name, two owners: kept apart by the prefix" if PREFIXED else "Service names this lab shares with others in the tenant (turn on the service prefix to separate them)",
                   f'fetch spans | filter isNotNull(service.name) | fieldsAdd base = {BASE}, mine = {OURS} | summarize ours = countIf(mine), others = countIf(not mine), by: {{base}} | filter ours > 0 and others > 0 | sort ours desc | limit 12', "table"), dict(x=8, y=20, w=16, h=7)),
    ("delta", data("Histogram metrics arriving thanks to cumulative-to-delta", f'timeseries requests = count(http.server.request.duration), by: {{service.name}}, filter: {OURS}', "lineChart",
                   "Dynatrace rejects cumulative sums and histograms (UNSUPPORTED_METRIC_TYPE_*). Bindplane converts them to delta in the pipeline."), dict(x=0, y=27, w=12, h=7)),
    ("noise_k", single("Share of all spans that are flagd flag evaluations (%)", f'fetch spans | filter {OURS} | summarize total = count(), flagd = countIf(service.name == "__SERVICE_PREFIX__flagd") | fieldsAdd flagd_pct = round(flagd * 100.0 / total, decimals: 1) | fields flagd_pct',
                       "Candidate for filtering or sampling at the collector"), dict(x=12, y=27, w=6, h=7)),
    ("noise_k2", single("Share of EKS logs that are Kafka (%)", 'fetch logs | filter k8s.cluster.name == "__EKS_CLUSTER_NAME__" | summarize total = count(), kafka = countIf(k8s.container.name == "kafka") | fieldsAdd kafka_pct = round(kafka * 100.0 / total, decimals: 1) | fields kafka_pct',
                        "Candidate for sampling or dedup at the collector"), dict(x=18, y=27, w=6, h=7)),
    ("flag_fail", data("Failing flagd evaluations by flag", 'fetch spans | filter deployment.environment == "__DEPLOYMENT_ENV__" and service.name == "__SERVICE_PREFIX__flagd" and request.is_failed == true | summarize failed = count(), by: {feature_flag.key} | sort failed desc | limit 8', "categoricalBarChart",
                       "The flags are requested but fail to evaluate: pure noise that would make flagd look unhealthy."), dict(x=0, y=34, w=12, h=7)),
    ("sev", data("EKS logs by level as received", 'fetch logs | filter k8s.cluster.name == "__EKS_CLUSTER_NAME__" | summarize logs = count(), by: {loglevel} | sort logs desc', "donutChart",
                 "Most container output is labelled SEVERE: fixable with a Bindplane severity processor or OpenPipeline."), dict(x=12, y=34, w=6, h=7)),
    ("sev_src", data("EKS logs labelled SEVERE, by container", 'fetch logs | filter k8s.cluster.name == "__EKS_CLUSTER_NAME__" and loglevel == "SEVERE" | summarize logs = count(), by: {k8s.container.name} | sort logs desc | limit 8', "categoricalBarChart"), dict(x=18, y=34, w=6, h=7)),
]

# --------------------------------------------------------------------------------------------
# Dashboard 3: GenAI, feature flags and incidents
# --------------------------------------------------------------------------------------------
D3_HEADER = """# GenAI, feature flags and incidents

**Break something, watch it surface.** Toggle a flag at __SHOP_URL__/feature/ (for example `productCatalogFailure` or `cartFailure`) and watch the failure charts below. Drive load at __SHOP_URL__/loadgen/. Chat with the GenAI agent at __SHOP_URL__/chatbot/.

The LLM is **replayed from recorded responses** (no live model, no token counts), but every agent step, tool call and model call is real OpenTelemetry GenAI telemetry."""

D3 = [
    ("header", md(D3_HEADER), dict(x=0, y=0, w=24, h=4)),
    ("g_runs", single("Agent runs", 'fetch spans | filter gen_ai.operation.name == "invoke_agent" | summarize runs = count()'), dict(x=0, y=4, w=6, h=3)),
    ("g_tools", single("Tool calls", 'fetch spans | filter gen_ai.operation.name == "execute_tool" | summarize tool_calls = count()'), dict(x=6, y=4, w=6, h=3)),
    ("g_chat", single("Model calls", 'fetch spans | filter gen_ai.operation.name == "chat" | summarize chats = count()'), dict(x=12, y=4, w=6, h=3)),
    ("g_fail", single("Failed GenAI spans (%)", 'fetch spans | filter isNotNull(gen_ai.operation.name) | summarize total = count(), failed = countIf(request.is_failed == true or span.status_code == "error") | fieldsAdd failed_pct = round(if(total > 0, failed * 100.0 / total, else: 0.0), decimals: 2) | fields failed_pct'), dict(x=18, y=4, w=6, h=3)),
    ("g_ops", data("GenAI operations", 'fetch spans | filter isNotNull(gen_ai.operation.name) | summarize calls = count(), by: {gen_ai.operation.name}', "donutChart"), dict(x=0, y=7, w=8, h=7)),
    ("g_toolsby", data("Tool usage", 'fetch spans | filter gen_ai.operation.name == "execute_tool" | summarize calls = count(), by: {gen_ai.tool.name} | sort calls desc | limit 10', "categoricalBarChart"), dict(x=8, y=7, w=8, h=7)),
    ("g_lat", data("Model call p95 latency", 'fetch spans | filter gen_ai.operation.name == "chat" | makeTimeseries p95 = percentile(duration, 95), interval: 1m', "lineChart"), dict(x=16, y=7, w=8, h=7)),
    ("g_tl", data("Tool calls over time", 'fetch spans | filter gen_ai.operation.name == "execute_tool" | makeTimeseries calls = count(), interval: 2m, by: {gen_ai.tool.name}', "areaChart"), dict(x=0, y=14, w=12, h=7)),
    ("g_runs_long", data("Longest agent runs (loop and runaway candidates)", 'fetch spans | filter isNotNull(gen_ai.operation.name) | summarize steps = count(), tool_calls = countIf(gen_ai.operation.name == "execute_tool"), chats = countIf(gen_ai.operation.name == "chat"), by: {trace.id} | sort steps desc | limit 10', "table",
                        "A high step count in one trace points to a looping agent (the aiRunawayAgent flag reproduces it)."), dict(x=12, y=14, w=12, h=7)),
    ("f_evals", data("Feature flag evaluations by flag", 'fetch spans | filter deployment.environment == "__DEPLOYMENT_ENV__" and service.name == "__SERVICE_PREFIX__flagd" and isNotNull(feature_flag.key) | makeTimeseries evals = count(), interval: 2m, by: {feature_flag.key}', "lineChart"), dict(x=0, y=21, w=12, h=7)),
    ("f_fail_time", data("Failed requests over time by service (flagd excluded)", f'fetch spans | filter {OURS} and {ROOT} and request.is_failed == true and service.name != "__SERVICE_PREFIX__flagd" | makeTimeseries failed = count(), interval: 1m, by: {{service.name}}', "areaChart",
                         "This is where a flag such as productCatalogFailure shows up as a spike."), dict(x=12, y=21, w=12, h=7)),
    ("f_pc", data("Product catalog: requests vs failures", 'fetch spans | filter deployment.environment == "__DEPLOYMENT_ENV__" and service.name == "__SERVICE_PREFIX__product-catalog" | makeTimeseries requests = count(), failed = countIf(request.is_failed == true), interval: 1m', "lineChart"), dict(x=0, y=28, w=12, h=7)),
    ("f_recent", data("Top failing operations (flagd excluded)", f'fetch spans | filter {OURS} and request.is_failed == true and service.name != "__SERVICE_PREFIX__flagd" | summarize failures = count(), by: {{service.name, span.name, span.status_message}} | sort failures desc | limit 10', "table"), dict(x=12, y=28, w=12, h=7)),
    ("f_logs", data("Warnings and errors in EC2 logs", f'fetch logs | filter {OURS} and in(loglevel, {{"ERROR", "WARN", "SEVERE"}}) and deployment.environment == "__DEPLOYMENT_ENV__" | summarize logs = count(), by: {{service.name, loglevel}} | sort logs desc | limit 12', "table"), dict(x=0, y=35, w=24, h=6)),
]

DASHBOARDS = [
    ("dashboard-1-overview.json", "__LAB_NAME__ | 1. Demo overview", D1),
    ("dashboard-2-bindplane-value.json", "__LAB_NAME__ | 2. Bindplane value", D2),
    ("dashboard-3-genai-flags-incidents.json", "__LAB_NAME__ | 3. GenAI, feature flags and incidents", D3),
]


def build(name, tiles):
    return {
        "name": name,
        "type": "dashboard",
        "content": {
            "version": 21,
            "variables": [],
            "tiles": {tid: tile for tid, tile, _ in tiles},
            "layouts": {tid: layout for tid, _, layout in tiles},
        },
    }


def fill(text):
    for k in TOKENS:
        text = text.replace(f"__{k}__", os.environ.get(k, f"<{k} not set>"))  # empty prefix stays empty
    return text


def dtctl(*args):
    return subprocess.run(["dtctl", "--context", CONTEXT, *args], capture_output=True, text=True)


def run_query(dql):
    now = datetime.datetime.now(datetime.timezone.utc)
    start = (now - datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
    end = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    p = dtctl("query", fill(dql), "--default-timeframe-start", start, "--default-timeframe-end", end)
    try:
        return json.loads(p.stdout)
    except Exception:
        return {"ok": False, "error": {"message": (p.stdout + p.stderr)[:300]}}


def validate():
    bad = 0
    for fname, name, tiles in DASHBOARDS:
        print(f"== {fill(name)}")
        for tid, tile, _ in tiles:
            if tile["type"] != "data":
                continue
            r = run_query(tile["query"])
            if not r.get("ok"):
                bad += 1
                print(f"  FAIL {tid:12} {tile['title']}: {str(r.get('error'))[:240]}")
                continue
            recs = (r.get("result") or {}).get("records") or []
            print(f"  {'ok   ' if recs else 'EMPTY'} {tid:12} {len(recs):3} rows  {tile['visualization']:20} {tile['title']}")
    print("query errors:", bad)
    return bad


def write_all():
    os.makedirs(OUT, exist_ok=True)
    paths = []
    for fname, name, tiles in DASHBOARDS:
        ids = [t for t, _, _ in tiles]
        assert len(ids) == len(set(ids)), "duplicate tile ids"
        path = os.path.join(OUT, fname)
        with open(path, "w") as f:
            f.write(fill(json.dumps(build(name, tiles), indent=2)))
        print("  wrote", fname, len(tiles), "tiles")
        paths.append((path, fill(name)))
    return paths


def existing_ids():
    p = dtctl("get", "dashboards", "-o", "json")
    try:
        data = json.loads(p.stdout)
    except Exception:
        return {}
    items = data.get("result", data) if isinstance(data, dict) else data
    return {d.get("name"): d.get("id") for d in items or [] if isinstance(d, dict)}


def deploy():
    if not CONTEXT:
        sys.exit("DTCTL_CONTEXT is empty: set it in lab.env to deploy dashboards")
    known = existing_ids()
    for path, name in write_all():
        args = ["apply", "-f", path] + (["--id", known[name]] if known.get(name) else [])
        p = dtctl(*args)
        verb = "updated" if known.get(name) else "created"
        print(f"  {verb if p.returncode == 0 else 'FAILED'}: {name} {(p.stderr or '').strip()[:200]}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "build"
    if cmd == "validate":
        sys.exit(1 if validate() else 0)
    elif cmd == "deploy":
        deploy()
    else:
        write_all()
