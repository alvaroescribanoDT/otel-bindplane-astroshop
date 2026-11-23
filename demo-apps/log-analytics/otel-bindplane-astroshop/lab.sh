#!/usr/bin/env bash
# OTel Astronomy Shop + Bindplane + Dynatrace lab. Everything is driven by lab.env (copy lab.env.example).
#
#   ./lab.sh doctor      check tools, lab.env values and access to AWS, Bindplane and Dynatrace
#   ./lab.sh up          everything below in order: bindplane -> infra -> wait -> dynatrace -> eks (if enabled)
#   ./lab.sh bindplane   render and apply the Bindplane processors, destinations and configurations, then roll out
#   ./lab.sh infra       terraform apply (shop host, IAM, S3 archive, Bindplane key in SSM Parameter Store)
#   ./lab.sh wait        wait until the shop host's collector is connected to Bindplane
#   ./lab.sh dynatrace   OpenPipeline routes for OTel host monitoring + the three dashboards (needs DTCTL_CONTEXT)
#   ./lab.sh eks         optional: shop + Bindplane node agent on an existing EKS cluster (ENABLE_EKS=true)
#   ./lab.sh pii on|off|status   optional synthetic PII logs for the redaction demo (no rebuild needed)
#   ./lab.sh check       verify the demo end to end (collector, data in Dynatrace, PII, sampling, S3, shop UI)
#   ./lab.sh info        print the URLs
#   ./lab.sh shell       open an SSM session on the shop host
#   ./lab.sh down        destroy the AWS resources (and the EKS add-on); Bindplane and Dynatrace objects stay
#   ./lab.sh clean       remove this lab's Bindplane resources and Dynatrace routes (after down)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
BUILD="$HERE/.build"
TF="$HERE/terraform"

say()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
on()   { [[ "${1:-false}" =~ ^(1|true|yes|on)$ ]]; }

# ---------------------------------------------------------------------------------------------------------------
# lab.env
# ---------------------------------------------------------------------------------------------------------------
load_env() {
  [[ -f lab.env ]] || die "lab.env not found: cp lab.env.example lab.env and fill it in"
  set -a
  # shellcheck disable=SC1091
  source lab.env
  set +a
  local v
  for v in LAB_NAME DEPLOYMENT_ENV OWNER AWS_REGION UI_ALLOWED_CIDR DT_ENV_URL DT_INGEST_TOKEN \
           BINDPLANE_REMOTE_URL BINDPLANE_OPAMP_URL BINDPLANE_API_KEY BINDPLANE_SECRET_KEY BINDPLANE_COLLECTOR_VERSION; do
    [[ -n "${!v:-}" && "${!v}" != *REPLACE_ME* ]] || die "lab.env: $v is not set"
  done
  [[ "$LAB_NAME" =~ ^[a-z0-9][a-z0-9-]{1,29}$ ]] || die "lab.env: LAB_NAME must be lowercase letters, digits, hyphens (max 30)"
  [[ "$DEPLOYMENT_ENV" =~ ^[A-Za-z0-9._-]+$ ]] || die "lab.env: DEPLOYMENT_ENV may only contain letters, digits, . _ -"
  [[ "$DT_ENV_URL" =~ ^https://[^[:space:]\"\']+$ ]] || die "lab.env: DT_ENV_URL must be an https URL"
  [[ "$DT_ENV_URL" != *".apps."* ]] || die "lab.env: DT_ENV_URL must be the environment URL (live/sprint), not the apps URL"
  [[ "$UI_ALLOWED_CIDR" =~ ^[0-9.]+/[0-9]+$ ]] || die "lab.env: UI_ALLOWED_CIDR must look like 203.0.113.10/32"
  for v in DT_INGEST_TOKEN BINDPLANE_API_KEY BINDPLANE_SECRET_KEY; do
    [[ "${!v}" =~ ^[^[:space:]\"\']+$ ]] || die "lab.env: $v contains spaces or quotes"
  done
  export DT_OTLP_URL="${DT_ENV_URL%/}/api/v2/otlp"
  # Environment ID (the destination type requires it even with a custom URL): host's first label, or the id after /e/.
  if [[ "$DT_ENV_URL" == */e/* ]]; then DT_ENV_ID="${DT_ENV_URL#*/e/}"; DT_ENV_ID="${DT_ENV_ID%%/*}"
  else DT_ENV_ID="${DT_ENV_URL#https://}"; DT_ENV_ID="${DT_ENV_ID%%.*}"; fi
  export DT_ENV_ID
  export ENABLE_S3_ARCHIVE="${ENABLE_S3_ARCHIVE:-true}" ENABLE_PII_GENERATOR="${ENABLE_PII_GENERATOR:-false}"
  export ENABLE_EKS="${ENABLE_EKS:-false}" DEMO_REF="${DEMO_REF:-3.1.0}"
  export ENABLE_SERVICE_PREFIX="${ENABLE_SERVICE_PREFIX:-false}"
  if on "$ENABLE_SERVICE_PREFIX"; then
    [[ "${SERVICE_PREFIX:-}" =~ ^[A-Za-z0-9-]+$ ]] \
      || die "lab.env: ENABLE_SERVICE_PREFIX=true needs SERVICE_PREFIX (your own, e.g. JD-LAB-; letters, digits, hyphens)"
    export EKS_SERVICE_PREFIX="${EKS_SERVICE_PREFIX:-${SERVICE_PREFIX%-}-EKS-}"
    [[ "$EKS_SERVICE_PREFIX" =~ ^[A-Za-z0-9-]+$ ]] || die "lab.env: EKS_SERVICE_PREFIX may only contain letters, digits, hyphens"
  else
    export SERVICE_PREFIX="" EKS_SERVICE_PREFIX=""   # no renaming: services keep the names the shop sends
  fi
  export EKS_DEPLOYMENT_ENV="${EKS_DEPLOYMENT_ENV:-$DEPLOYMENT_ENV-eks}"
  export EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-none}"
  [[ -n "${AWS_PROFILE:-}" ]] || unset AWS_PROFILE
  export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
  export TF_VAR_lab_name="$LAB_NAME" TF_VAR_owner="$OWNER" TF_VAR_aws_profile="${AWS_PROFILE:-}" \
         TF_VAR_region="$AWS_REGION" TF_VAR_az="${AWS_AZ:-}" TF_VAR_ui_allowed_cidr="$UI_ALLOWED_CIDR" \
         TF_VAR_shop_instance_type="${SHOP_INSTANCE_TYPE:-m6i.xlarge}" TF_VAR_demo_ref="$DEMO_REF" \
         TF_VAR_deployment_env="$DEPLOYMENT_ENV" TF_VAR_bindplane_opamp_url="$BINDPLANE_OPAMP_URL" \
         TF_VAR_bindplane_secret_key="$BINDPLANE_SECRET_KEY" \
         TF_VAR_bindplane_collector_version="$BINDPLANE_COLLECTOR_VERSION" \
         TF_VAR_enable_s3_archive="$ENABLE_S3_ARCHIVE" \
         TF_VAR_enable_elastic_ip="${ENABLE_ELASTIC_IP:-false}"
  BP_PROFILE="$LAB_NAME"
  # Bindplane resource names are LAB_NAME-<name> (same rule as scripts/render.py), so labs can share a project.
  SHOP_CONFIG="$LAB_NAME-shop-agent" EKS_CONFIG="$LAB_NAME-eks-logs"
  ENVOY_SAMPLER="sampling/$LAB_NAME-sample-envoy-ok"
  export TF_VAR_collector_labels="configuration=$SHOP_CONFIG,role=shop"
}

bp() { bindplane --profile "$BP_PROFILE" "$@"; }

bp_profile() {
  # A CLI profile per lab keeps the API key out of every command line after this one.
  # Project-scoped keys (bps_...) also need the project ID.
  bindplane profile set "$BP_PROFILE" --remote-url "$BINDPLANE_REMOTE_URL" --api-key "$BINDPLANE_API_KEY" \
    ${BINDPLANE_PROJECT:+--project "$BINDPLANE_PROJECT"} >/dev/null
}

account_id() { aws sts get-caller-identity --query Account --output text; }

s3_bucket() {
  if on "$ENABLE_S3_ARCHIVE"; then
    # Terraform's output once the bucket exists; before the first apply, the same name terraform/s3.tf builds.
    S3_BUCKET="${S3_BUCKET:-$(tf_out archive_bucket)}"
    [[ -n "$S3_BUCKET" ]] || S3_BUCKET="$LAB_NAME-logs-$(account_id)" || die "cannot reach AWS to name the S3 bucket"
  else
    S3_BUCKET=disabled
  fi
  export S3_BUCKET
}

tf_out() { terraform -chdir="$TF" output -raw "$1" 2>/dev/null || true; }

dt() { dtctl --context "$DTCTL_CONTEXT" "$@"; }

# First record of a DQL query as compact JSON ("" on error or no rows).
dq() {
  dt query "$1" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    r = (json.load(sys.stdin).get("result") or {}).get("records") or []
    print(json.dumps(r[0]) if r else "")
except Exception:
    print("")'
}
field() { python3 -c 'import json,sys; d=json.loads(sys.argv[1] or "{}"); print(d.get(sys.argv[2]) or 0)' "$1" "$2"; }

# ---------------------------------------------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------------------------------------------
cmd_doctor() {
  load_env
  say "Tools"
  local t missing=0
  for t in terraform aws bindplane python3 curl; do
    if command -v "$t" >/dev/null; then ok "$t"; else fail "$t not found"; missing=1; fi
  done
  python3 -c 'import yaml' 2>/dev/null && ok "python3 PyYAML" || { fail "PyYAML missing: python3 -m pip install --user pyyaml"; missing=1; }
  command -v session-manager-plugin >/dev/null && ok "session-manager-plugin" || warn "session-manager-plugin missing: ./lab.sh shell will not work"
  if [[ -n "${DTCTL_CONTEXT:-}" ]]; then
    command -v dtctl >/dev/null && ok "dtctl" || { fail "dtctl not found (or empty DTCTL_CONTEXT to skip)"; missing=1; }
  else
    warn "DTCTL_CONTEXT empty: Dynatrace routes, dashboards and checks are skipped"
  fi
  if on "$ENABLE_EKS"; then
    for t in kubectl helm; do command -v "$t" >/dev/null && ok "$t" || { fail "$t not found (ENABLE_EKS=true)"; missing=1; }; done
  fi
  [[ $missing == 0 ]] || die "install the missing tools first"

  say "AWS"
  local acct
  acct=$(account_id 2>/dev/null) && ok "credentials work (account $acct, region $AWS_REGION)" || die "aws sts get-caller-identity failed: check AWS_PROFILE / credentials"

  say "Bindplane"
  bp_profile
  bp get configurations >/dev/null 2>&1 && ok "API key works ($BINDPLANE_REMOTE_URL)" \
    || die "Bindplane API key rejected (a project-scoped bps_ key also needs BINDPLANE_PROJECT)"

  say "Dynatrace"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$DT_OTLP_URL/v1/logs" \
    -H "Authorization: Api-Token $DT_INGEST_TOKEN" -H 'Content-Type: application/x-protobuf' --data-binary '')  # empty export
  case "$code" in
    200|204) ok "ingest token accepted by $DT_OTLP_URL" ;;
    401|403) die "ingest token rejected ($code): needs openTelemetryTrace.ingest, metrics.ingest, logs.ingest" ;;
    *) die "OTLP endpoint answered $code: check DT_ENV_URL" ;;
  esac
  if [[ -n "${DTCTL_CONTEXT:-}" ]]; then
    dt query 'fetch logs, from:now()-1m | limit 1' -o json >/dev/null 2>&1 && ok "dtctl context $DTCTL_CONTEXT can query" \
      || die "dtctl context $DTCTL_CONTEXT cannot query (dtctl auth login?)"
    python3 dynatrace/openpipeline_routes.py status || true
  fi
  ok "lab.env looks complete"
}

# ---------------------------------------------------------------------------------------------------------------
# bindplane
# ---------------------------------------------------------------------------------------------------------------
cmd_bindplane() {
  load_env
  bp_profile
  s3_bucket
  say "Render Bindplane resources"
  python3 scripts/render.py
  say "Apply to Bindplane"
  local f
  local out
  for f in "$BUILD"/bindplane/*.yaml; do
    out=$(bp apply -f "$f" 2>&1) || { echo "$out" | sed 's/^/  /'
      [[ "$out" == *403* ]] && die "Bindplane refused the write (403): the API key needs a role that can create resources"
      die "bindplane apply failed for $(basename "$f")"; }
    echo "$out" | sed 's/^/  /'
    # apply exits 0 even when it rejects a resource as invalid
    [[ "$out" != *" invalid"* ]] || die "Bindplane rejected a resource in $(basename "$f") (see above)"
  done
  say "Roll out"
  bp rollout start "$SHOP_CONFIG" | sed 's/^/  /'
  if on "$ENABLE_EKS"; then bp rollout start "$EKS_CONFIG" | sed 's/^/  /'; fi
}

# ---------------------------------------------------------------------------------------------------------------
# infra
# ---------------------------------------------------------------------------------------------------------------
cmd_infra() {
  load_env
  say "Terraform apply"
  terraform -chdir="$TF" init -input=false -upgrade >/dev/null
  terraform -chdir="$TF" apply -input=false -auto-approve
  cmd_info
}

cmd_wait() {
  load_env
  bp_profile
  local host short i status
  host=$(tf_out shop_host_name); short=${host%%.*}
  [[ -n "$short" ]] || die "no shop host yet: run ./lab.sh infra"
  say "Waiting for collector $short to connect to Bindplane (boot + Docker + collector install: ~5 min)"
  for i in $(seq 1 60); do
    status=$(bp get agents -l "configuration=$SHOP_CONFIG" 2>/dev/null | awk -v h="$short" '$2 == h {print $4}')
    if [[ "$status" == Connected ]]; then ok "collector connected"; break; fi
    sleep 15
  done
  [[ "${status:-}" == Connected ]] || die "collector not connected after 15 min: ./lab.sh shell, then: sudo tail -50 /var/log/cloud-init-output.log"
  say "The shop keeps pulling images for a few minutes; the UI answers when it is ready: $(tf_out shop_url)"
}

# ---------------------------------------------------------------------------------------------------------------
# dynatrace
# ---------------------------------------------------------------------------------------------------------------
cmd_dynatrace() {
  load_env
  if [[ -z "${DTCTL_CONTEXT:-}" ]]; then warn "DTCTL_CONTEXT empty: skipping (see README, manual steps)"; return; fi
  export SHOP_URL SHOP_HOST_NAME
  SHOP_URL=$(tf_out shop_url); SHOP_HOST_NAME=$(tf_out shop_host_name)
  say "OpenPipeline routes (OpenTelemetry Host Monitoring)"
  python3 dynatrace/openpipeline_routes.py apply
  say "Dashboards"
  python3 dynatrace/build_dashboards.py deploy
}

# ---------------------------------------------------------------------------------------------------------------
# eks (optional add-on on an existing cluster)
# ---------------------------------------------------------------------------------------------------------------
kc() { kubectl --context "$EKS_KUBE_CONTEXT" "$@"; }

cmd_eks() {
  load_env
  on "$ENABLE_EKS" || { warn "ENABLE_EKS is not true: skipping"; return; }
  [[ -n "${EKS_KUBE_CONTEXT:-}" && "$EKS_CLUSTER_NAME" != none ]] || die "set EKS_KUBE_CONTEXT and EKS_CLUSTER_NAME"
  say "Astronomy Shop on $EKS_CLUSTER_NAME (namespace otel-demo)"
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
  helm repo update open-telemetry >/dev/null
  helm --kube-context "$EKS_KUBE_CONTEXT" upgrade --install otel-demo open-telemetry/opentelemetry-demo \
    --version 0.42.6 -n otel-demo --create-namespace -f eks/shop-values.yaml
  say "Bindplane node agent (namespace bindplane-agent)"
  kc create namespace bindplane-agent --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc -n bindplane-agent create secret generic bindplane-secret --from-literal=secret-key="$BINDPLANE_SECRET_KEY" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  sed -e "s|__BINDPLANE_OPAMP_URL__|$BINDPLANE_OPAMP_URL|" -e "s|__BINDPLANE_COLLECTOR_VERSION__|$BINDPLANE_COLLECTOR_VERSION|" \
    -e "s|__EKS_CONFIG__|$EKS_CONFIG|" eks/bindplane-node-agent.yaml | kc apply -f -
}

cmd_eks_down() {
  load_env
  on "$ENABLE_EKS" || return 0
  say "Removing the EKS add-on"
  helm --kube-context "$EKS_KUBE_CONTEXT" uninstall otel-demo -n otel-demo || true
  sed -e "s|__BINDPLANE_OPAMP_URL__|$BINDPLANE_OPAMP_URL|" -e "s|__BINDPLANE_COLLECTOR_VERSION__|$BINDPLANE_COLLECTOR_VERSION|" \
    -e "s|__EKS_CONFIG__|$EKS_CONFIG|" eks/bindplane-node-agent.yaml | kc delete --ignore-not-found -f - || true
}

# ---------------------------------------------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------------------------------------------
cmd_check() {
  load_env
  bp_profile
  s3_bucket
  local host short url n r
  host=$(tf_out shop_host_name); short=${host%%.*}; url=$(tf_out shop_url)

  say "Bindplane"
  bp get agents -l "configuration=$SHOP_CONFIG" 2>/dev/null | awk -v h="$short" 'NR==1 || $2 == h' | sed 's/^/  /'
  bp rollout status "$SHOP_CONFIG" 2>/dev/null | sed 's/^/  /'

  say "Shop UI"
  n=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url/" || true)
  [[ "$n" == 200 ]] && ok "$url answers 200" || fail "$url answers ${n:-nothing} (still starting? ./lab.sh shell, docker ps)"

  if [[ -n "${DTCTL_CONTEXT:-}" ]]; then
    say "Dynatrace (last 10 minutes)"
    r=$(dq "fetch spans, from:now()-10m | filter deployment.environment == \"$DEPLOYMENT_ENV\" | summarize spans = count(), services = countDistinct(service.name), prefixed = countIf(startsWith(service.name, \"${SERVICE_PREFIX:-none}\"))")
    n=$(field "$r" spans); [[ "$n" -gt 0 ]] && ok "spans: $n from $(field "$r" services) services" || fail "no spans with deployment.environment $DEPLOYMENT_ENV"
    if on "$ENABLE_SERVICE_PREFIX" && [[ "$n" -gt 0 ]]; then
      [[ "$(field "$r" prefixed)" == "$n" ]] && ok "every service is named $SERVICE_PREFIX*" || warn "$(field "$r" prefixed) of $n spans carry the prefix $SERVICE_PREFIX (rollout still in progress?)"
    fi
    r=$(dq "fetch logs, from:now()-10m | filter deployment.environment == \"$DEPLOYMENT_ENV\" | summarize logs = count()")
    n=$(field "$r" logs); [[ "$n" -gt 0 ]] && ok "logs: $n" || fail "no logs with deployment.environment $DEPLOYMENT_ENV"
    r=$(dq "timeseries v = avg(system.cpu.utilization), from:now()-10m, filter: host.name == \"$host\" | fieldsAdd n = arraySize(v) | fields n")
    [[ -n "$r" ]] && ok "host metrics for $host" || fail "no host metrics for $host"
    r=$(dq "fetch logs, from:now()-10m | filter deployment.environment == \"$DEPLOYMENT_ENV\" and in(service.name, array(\"${SERVICE_PREFIX}checkout\", \"${SERVICE_PREFIX}payment\")) | summarize n = count(), raw = countIf(contains(content, \"4111111111111111\") or contains(content, \"@example.com\"))")
    if [[ "$(field "$r" n)" -gt 0 ]]; then
      [[ "$(field "$r" raw)" == 0 ]] && ok "PII: $(field "$r" n) checkout/payment logs, 0 raw card numbers or emails" \
        || fail "PII: $(field "$r" raw) logs with RAW card numbers or emails"
    else
      warn "no checkout/payment logs with PII: the generator is off (./lab.sh pii on) or just started"
    fi
    r=$(dq "timeseries i = sum(otelcol_processor_incoming_items), o = sum(otelcol_processor_outgoing_items), from:now()-10m, filter: processor == \"$ENVOY_SAMPLER\" and otel.signal == \"logs\" | fieldsAdd i = arraySum(i), o = arraySum(o) | fields i, o")
    if [[ -n "$r" && "$(field "$r" i)" != 0 ]]; then
      ok "envoy access-log sampling: $(python3 -c "import json,sys;d=json.loads(sys.argv[1]);print(round(100-100*d['o']/d['i']))" "$r")% dropped (expect ~40-50%)"
    else
      warn "no collector self-monitoring metrics for the envoy sampler yet"
    fi
    r=$(dq "smartscapeNodes OTEL_HOST | filter name == \"$host\" | summarize n = count()")
    [[ "$(field "$r" n)" -gt 0 ]] && ok "OTEL_HOST entity exists" || warn "no OTEL_HOST entity (extension + routes, see README)"
  fi

  if on "$ENABLE_S3_ARCHIVE"; then
    say "S3 archive"
    local listing
    if ! listing=$(aws s3 ls "s3://$S3_BUCKET/shop-logs/" --recursive 2>&1); then
      if [[ "$listing" == *"NoSuchKey"* || -z "$listing" ]]; then
        fail "no objects in s3://$S3_BUCKET/shop-logs/ yet (written every ~10 s once logs flow)"
      else
        warn "cannot list s3://$S3_BUCKET (AWS credentials expired?): $(echo "$listing" | grep -m1 . | cut -c1-120)"
      fi
    else
      n=$(echo "$listing" | grep -c . || true)
      ok "$n objects in s3://$S3_BUCKET/shop-logs/ (newest: $(echo "$listing" | sort | tail -1 | awk '{print $1" "$2}'))"
    fi
  fi
}

# ---------------------------------------------------------------------------------------------------------------
# pii: optional synthetic PII logs, switched on the running host over SSM
# ---------------------------------------------------------------------------------------------------------------
# Run a shell script on the shop host as root (SSM Run Command) and print its output.
ssm_run() {
  local id cmd status i
  id=$(tf_out shop_instance_id); [[ -n "$id" ]] || die "no shop host yet: run ./lab.sh infra"
  cmd=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript --comment "$LAB_NAME lab.sh" \
    --parameters "$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]], "executionTimeout": ["1800"]}))' "$1")" \
    --query Command.CommandId --output text)
  for i in $(seq 1 400); do   # up to ~20 min: on a fresh host the script first waits for the bootstrap to finish
    status=$(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in Success|Failed|Cancelled|TimedOut) break ;; esac
    sleep 3
  done
  aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" --query StandardOutputContent --output text | sed 's/^/  /'
  [[ "$status" == Success ]] || { aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
    --query StandardErrorContent --output text | sed 's/^/  /'; die "command on the shop host ended with status $status"; }
}

PII_PRE='set -e
for i in $(seq 1 120); do [ -f /var/log/lab-bootstrap-done ] && break; [ "$i" = 1 ] && echo "waiting for the host bootstrap to finish"; sleep 10; done
[ -f /var/log/lab-bootstrap-done ] || { echo "host bootstrap not finished after 20 min" >&2; exit 1; }
cd /opt/opentelemetry-demo
sed -i "/^COMPOSE_PROFILES=/d" .env'
PII_STATUS='docker ps -a --filter name=^pii-log-generator$ --format "pii-log-generator: {{.Status}}" | grep . || echo "pii-log-generator: not running"'

cmd_pii() {
  load_env
  case "${1:-status}" in
    on)
      say "Synthetic PII logs: ON (~4 orders/min as checkout/payment, fake cards and emails, lab.synthetic=true)"
      ssm_run "$PII_PRE
echo COMPOSE_PROFILES=pii-demo >> .env
docker compose up -d pii-log-generator
$PII_STATUS" ;;
    off)
      say "Synthetic PII logs: OFF"
      ssm_run "$PII_PRE
docker compose --profile pii-demo rm -sf pii-log-generator
$PII_STATUS" ;;
    status)
      ssm_run "$PII_STATUS" ;;
    *) die "usage: ./lab.sh pii on|off|status" ;;
  esac
}

# ---------------------------------------------------------------------------------------------------------------
# info / shell / down / clean
# ---------------------------------------------------------------------------------------------------------------
cmd_info() {
  load_env
  local url; url=$(tf_out shop_url)
  [[ -n "$url" ]] || { warn "no shop host (./lab.sh infra)"; return; }
  say "URLs"
  cat <<EOF
  Shop            $url/
  Load generator  $url/loadgen/
  Feature flags   $url/feature/
  GenAI chatbot   $url/chatbot/
  Grafana         $url/grafana/
  Jaeger          $url/jaeger/ui/
  Host name       $(tf_out shop_host_name)   (host.name in Dynatrace)
  S3 archive      $(tf_out archive_bucket)
  Shell           ./lab.sh shell
EOF
}

cmd_shell() {
  load_env
  aws ssm start-session --target "$(tf_out shop_instance_id)"
}

cmd_down() {
  load_env
  cmd_eks_down
  say "Terraform destroy"
  terraform -chdir="$TF" destroy -input=false -auto-approve
  warn "Bindplane resources, Dynatrace routes and dashboards are kept: ./lab.sh clean removes the first two"
}

cmd_clean() {
  load_env
  bp_profile
  s3_bucket
  say "Remove this lab's Bindplane resources"
  # Render every optional part, so whatever an earlier run with other settings created is deleted too.
  ENABLE_EKS=true ENABLE_S3_ARCHIVE=true ENABLE_SERVICE_PREFIX=true EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-none}" \
    python3 scripts/render.py >/dev/null
  local f
  for f in $(ls -r "$BUILD"/bindplane/*.yaml); do   # configurations first, then destinations, bundles, processors
    bp delete -f "$f" 2>&1 | sed 's/^/  /' || true
  done
  if [[ -n "${DTCTL_CONTEXT:-}" ]]; then
    say "Remove this lab's OpenPipeline routes (dashboards are left for you to delete)"
    python3 dynatrace/openpipeline_routes.py remove
  fi
}

cmd_up() {
  cmd_doctor
  cmd_bindplane
  cmd_infra
  cmd_wait
  cmd_dynatrace
  cmd_eks
  if on "$ENABLE_PII_GENERATOR"; then cmd_pii on; fi
  say "Done. Give it ~10 minutes for data to build up, then: ./lab.sh check"
}

case "${1:-help}" in
  doctor|up|bindplane|infra|wait|dynatrace|eks|check|info|shell|down|clean) "cmd_${1}" ;;
  pii) cmd_pii "${2:-status}" ;;
  eks-down) cmd_eks_down ;;
  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" ;;
esac
