#!/usr/bin/env python3
"""Route this lab's OTLP data to the OpenTelemetry Host Monitoring extension's pipelines, so Dynatrace creates
OTEL_HOST / OTEL_PROCESS entities and links services and logs to the host.

    openpipeline_routes.py status    show whether the extension pipelines and this lab's routes exist
    openpipeline_routes.py apply     add (or update) one route per signal: logs, metrics, spans
    openpipeline_routes.py remove    delete this lab's routes again

Only entries whose description starts with "<LAB_NAME> -" are touched; every other route in the tenant is kept as
is and in order. Each change is a read-modify-write of the routing settings object, and the previous object is
saved to .build/dynatrace/ first. Needs: dtctl, DTCTL_CONTEXT, LAB_NAME, DEPLOYMENT_ENV.
"""
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, ".build", "dynatrace")
SIGNALS = ["logs", "metrics", "spans"]
CTX = os.environ.get("DTCTL_CONTEXT", "")
LAB = os.environ.get("LAB_NAME", "")
ENV = os.environ.get("DEPLOYMENT_ENV", "")


def dtctl(*args):
    p = subprocess.run(["dtctl", "--context", CTX, *args], capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"dtctl {' '.join(args)} failed: {(p.stderr or p.stdout).strip()[:400]}")
    return p.stdout


def get_objects(schema):
    data = json.loads(dtctl("get", "settings", "--schema", schema, "-o", "json"))
    return data.get("result", data) if isinstance(data, dict) else data


def extension_pipeline_id(signal):
    for o in get_objects(f"builtin:openpipeline.{signal}.pipelines") or []:
        if o["value"].get("customId") == f"extension.opentelemetry-{signal}":
            return o["objectId"]
    return None


def routing(signal):
    objs = get_objects(f"builtin:openpipeline.{signal}.routing") or []
    if not objs:
        sys.exit(f"no {signal} routing object found in the tenant")
    return objs[0]


def ours(entry):
    return entry.get("description", "").startswith(f"{LAB} -")


def save(signal, obj):
    payload = {k: obj[k] for k in ("objectId", "schemaId", "scope", "value") if k in obj}
    os.makedirs(OUT, exist_ok=True)
    stamp = time.strftime("%Y%m%dT%H%M%S")
    with open(os.path.join(OUT, f"routing-{signal}-backup-{stamp}.json"), "w") as f:
        json.dump(routing(signal), f, indent=1)
    path = os.path.join(OUT, f"routing-{signal}.json")
    with open(path, "w") as f:
        json.dump(payload, f, indent=1)
    dtctl("apply", "-f", path)


def status():
    for s in SIGNALS:
        pid = extension_pipeline_id(s)
        mine = [e for e in routing(s)["value"]["routingEntries"] if ours(e)]
        print(f"  {s:8} extension pipeline: {'yes' if pid else 'MISSING'}   lab route: {'yes' if mine else 'no'}")


def apply():
    for s in SIGNALS:
        pid = extension_pipeline_id(s)
        if not pid:
            sys.exit(f"pipeline extension.opentelemetry-{s} not found: install 'OpenTelemetry Host Monitoring' "
                     "from Dynatrace Hub first (see README)")
        obj = routing(s)
        entry = {
            "description": f"{LAB} - Bindplane lab OTel host monitoring",
            "enabled": True,
            "matcher": f'matchesValue(deployment.environment, "{ENV}") and isNotNull(host.id)',
            "pipelineId": pid,
            "pipelineType": "custom",
        }
        entries = [e for e in obj["value"]["routingEntries"] if not ours(e)]
        # First match wins: put the lab route first so a broader route elsewhere cannot catch our data.
        obj["value"]["routingEntries"] = [entry] + entries
        save(s, obj)
        print(f"  {s:8} route -> extension.opentelemetry-{s}")


def remove():
    for s in SIGNALS:
        obj = routing(s)
        before = obj["value"]["routingEntries"]
        after = [e for e in before if not ours(e)]
        if len(after) == len(before):
            print(f"  {s:8} nothing to remove")
            continue
        obj["value"]["routingEntries"] = after
        save(s, obj)
        print(f"  {s:8} lab route removed")


if __name__ == "__main__":
    if not (CTX and LAB and ENV):
        sys.exit("set DTCTL_CONTEXT, LAB_NAME and DEPLOYMENT_ENV (lab.sh does this from lab.env)")
    {"status": status, "apply": apply, "remove": remove}[sys.argv[1] if len(sys.argv) > 1 else "status"]()
