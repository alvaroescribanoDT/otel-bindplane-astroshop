#!/usr/bin/env python3
"""Render the Bindplane templates in bindplane/ into .build/bindplane/ using values from the environment.

lab.sh exports lab.env plus the derived values (DT_OTLP_URL, S3_BUCKET) before calling this. Placeholders are
{{VAR}}; any placeholder without a value is an error, so a half-filled lab.env never reaches Bindplane.

Feature toggles handled here:
  ENABLE_SERVICE_PREFIX=false -> the lab-prefix-service-name-* processors are removed everywhere (bundle, Docker
                                 logs chain, resource list); service names stay as the shop sends them
  ENABLE_S3_ARCHIVE=false     -> the S3 destination and its routes are removed from the shop configuration
  ENABLE_EKS=false            -> the EKS configuration and its two EKS-only processors are not rendered
"""
import os
import re
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "bindplane")
OUT = os.path.join(ROOT, ".build", "bindplane")
PLACEHOLDER = re.compile(r"\{\{([A-Z0-9_]+)\}\}")
MAY_BE_EMPTY = {"SERVICE_PREFIX", "EKS_SERVICE_PREFIX"}  # empty when ENABLE_SERVICE_PREFIX=false
EKS_ONLY = ("lab-eks-service-name", "lab-eks-tag-fields")
PREFIX_PROCESSORS = ("lab-prefix-service-name-logs", "lab-prefix-service-name-metrics", "lab-prefix-service-name-traces")


def on(name):
    return os.environ.get(name, "false").strip().lower() in ("1", "true", "yes", "on")


def fill(text, path):
    missing = sorted({m for m in PLACEHOLDER.findall(text)
                      if (m not in os.environ if m in MAY_BE_EMPTY else not os.environ.get(m))})
    if missing:
        sys.exit(f"render: {os.path.basename(path)} needs {', '.join(missing)} (set them in lab.env)")
    # Plain text substitution: some placeholders sit inside OTTL strings. lab.sh validates the value formats first
    # (prefixes are [A-Za-z0-9-], no quotes or spaces anywhere), so the result is always valid YAML.
    return PLACEHOLDER.sub(lambda m: os.environ[m.group(1)], text)


def drop_s3(doc):
    spec = doc["spec"]
    spec["destinations"] = [d for d in spec.get("destinations", []) if d.get("id") != "d-s3"]
    for s in spec.get("sources", []):
        for route_list in (s.get("routes") or {}).values():
            for r in route_list:
                r["components"] = [c for c in r.get("components", []) if c != "destinations/d-s3"]
    return doc


def drop_prefix(doc):
    """Remove every reference to the service-name prefix processors from a configuration or bundle."""
    if doc["kind"] == "Configuration":
        for comp in doc["spec"].get("sources", []) + doc["spec"].get("destinations", []):
            if comp.get("processors"):
                comp["processors"] = [p for p in comp["processors"] if p.get("name") not in PREFIX_PROCESSORS]
    elif doc["spec"].get("type") == "processor_bundle":
        doc["spec"]["processors"] = [p for p in doc["spec"]["processors"] if p.get("name") not in PREFIX_PROCESSORS]
    return doc


def bp_name(name):
    """Resource name in Bindplane: LAB_NAME-<template name without lab-/Lab-/otel->. lab.sh uses the same rule.
    Every lab gets its own set, so several labs can share one Bindplane project without touching each other."""
    for p in ("lab-", "Lab-", "otel-"):
        if name.startswith(p):
            name = name[len(p):]
            break
    return f"{os.environ['LAB_NAME']}-{name}"


def namespace(doc):
    doc["metadata"]["name"] = bp_name(doc["metadata"]["name"])
    spec = doc["spec"]
    if doc["kind"] == "Configuration":
        sel = spec.get("selector", {}).get("matchLabels", {})
        if "configuration" in sel:
            sel["configuration"] = doc["metadata"]["name"]  # collectors join through the label configuration=<name>
        for comp in spec.get("sources", []) + spec.get("destinations", []):
            if comp.get("name"):  # a reference to a shared destination (sources here are all inline)
                comp["name"] = bp_name(comp["name"])
            for p in comp.get("processors") or []:
                if p.get("name"):
                    p["name"] = bp_name(p["name"])
    elif spec.get("type") == "processor_bundle":
        for p in spec["processors"]:
            p["name"] = bp_name(p["name"])
    return doc


def main():
    if not os.environ.get("LAB_NAME"):
        sys.exit("render: LAB_NAME is not set")
    os.makedirs(OUT, exist_ok=True)
    for old in os.listdir(OUT):
        os.remove(os.path.join(OUT, old))
    for name in sorted(os.listdir(SRC)):
        if not name.endswith(".yaml"):
            continue
        if name.startswith("50-") and not on("ENABLE_EKS"):
            continue
        path = os.path.join(SRC, name)
        docs = [d for d in yaml.safe_load_all(fill(open(path).read(), path)) if d]
        if not on("ENABLE_EKS"):
            docs = [d for d in docs if d["metadata"]["name"] not in EKS_ONLY]
        if not on("ENABLE_SERVICE_PREFIX"):
            docs = [drop_prefix(d) for d in docs if d["metadata"]["name"] not in PREFIX_PROCESSORS]
        if not on("ENABLE_S3_ARCHIVE"):
            docs = [d for d in docs if d["metadata"]["name"] not in ("shop-s3-archive", "lab-s3-batch")]
            docs = [drop_s3(d) if d["kind"] == "Configuration" else d for d in docs]
        docs = [namespace(d) for d in docs]
        with open(os.path.join(OUT, name), "w") as f:
            f.write("".join("---\n" + yaml.safe_dump(d, sort_keys=False, width=200, allow_unicode=True) for d in docs))
        os.chmod(os.path.join(OUT, name), 0o600)  # the destination file carries the ingest token
        print(f"  rendered {name} ({len(docs)} resources)")


if __name__ == "__main__":
    main()
