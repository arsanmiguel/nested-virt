#!/usr/bin/env bash
# Definitive lab verification — structured checks, GREEN/RED artifacts, SSM + S3 record.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=s3-lab-common.sh
source "${SCRIPT_DIR}/s3-lab-common.sh"

SITE_ID="$(lab_site_id)"
REGION="$(lab_region)"
INSTANCE_ID="$(lab_instance_id)"
VERIFY_JSON="${LAB_STATE_DIR}/lab-verification.json"
STATUS_FILE="${LAB_STATE_DIR}/LAB_STATUS"
RECORD=0
AGGREGATE=0

usage() {
  echo "usage: $0 [--record] [--aggregate-lab]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --record) RECORD=1 ;;
    --aggregate-lab) AGGREGATE=1 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

check_ok() {
  CHECKS+=("$1")
  CHECK_OK+=("true")
  lab_log "VERIFY OK check=$1"
}

check_fail() {
  local id="$1" reason="${2:-failed}"
  CHECKS+=("$id")
  CHECK_OK+=("false")
  FAIL=1
  lab_log "VERIFY FAIL check=${id} reason=${reason}"
}

run_routing_and_internet() {
  s3_fetch_script routing-proof-on-host.sh /tmp/routing-proof-on-host.sh
  if /tmp/routing-proof-on-host.sh all; then
    check_ok routing-layer-all
  else
    check_fail routing-layer-all
  fi
}

run_sanity_checks() {
  local phase boot
  boot="$(cat "${LAB_STATE_DIR}/bootstrap-phase" 2>/dev/null || echo none)"
  if [[ "$boot" == complete ]]; then
    check_ok bootstrap-complete
  else
    check_fail bootstrap-complete "phase=${boot}"
  fi

  if ping -c1 -W3 "10.${SITE_ID}.1.10" >/dev/null 2>&1; then
    check_ok l1-guest-ping
  else
    check_fail l1-guest-ping
  fi

  if ping -c1 -W3 "10.${SITE_ID}.1.20" >/dev/null 2>&1; then
    check_ok l2-inner-ping
  else
    check_fail l2-inner-ping
  fi

  if grep -q '^port=0' /etc/nested-virt-dnsmasq.conf 2>/dev/null; then
    check_ok dnsmasq-dhcp-only
  else
    check_fail dnsmasq-dhcp-only
  fi

  if virsh dumpxml win-hv-nested 2>/dev/null | grep -q "listen='127.0.0.1'"; then
    check_ok vnc-localhost
  else
    check_fail vnc-localhost
  fi
}

write_site_json() {
  local status ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if (( FAIL )); then
    status=RED
  else
    status=GREEN
  fi

  python3 - "$VERIFY_JSON" "$status" "$SITE_ID" "$INSTANCE_ID" "$ts" "${CHECKS[@]}" -- "${CHECK_OK[@]}" <<'PY'
import json, sys
path, status, site_id, iid, ts = sys.argv[1:6]
rest = sys.argv[6:]
sep = rest.index("--")
names, oks = rest[:sep], rest[sep + 1:]
checks = [{"id": n, "ok": o == "true"} for n, o in zip(names, oks)]
doc = {
    "status": status,
    "site_id": site_id,
    "instance_id": iid,
    "verified_at": ts,
    "checks": checks,
}
with open(path, "w") as f:
    json.dump(doc, f, indent=2)
print(json.dumps(doc))
PY

  echo "$status" > "$STATUS_FILE"
  lab_log "VERIFY site=${SITE_ID} status=${status} json=${VERIFY_JSON}"
}

publish_site_record() {
  local status param bucket prefix
  status="$(python3 -c "import json; print(json.load(open('${VERIFY_JSON}'))['status'])")"
  param="/nested-virt/lab/site-${SITE_ID}/verification"

  aws ssm put-parameter --region "$REGION" --name "$param" \
    --value "$(cat "$VERIFY_JSON")" --type String --overwrite

  aws cloudwatch put-metric-data --region "$REGION" \
    --namespace NestedVirt/LabVerification \
    --metric-data "MetricName=SiteStatus,Dimensions=[{Name=SiteId,Value=${SITE_ID}}],Value=$([[ $status == GREEN ]] && echo 1 || echo 0),Unit=Count"

  bucket="$(lab_bootstrap_bucket)"
  prefix="$(lab_s3_prefix)"
  aws s3 cp "$VERIFY_JSON" "${prefix}/lab-verification/site-${SITE_ID}.json" --region "$REGION"
  aws s3 cp "$STATUS_FILE" "${prefix}/lab-verification/site-${SITE_ID}.status" --region "$REGION"
  lab_log "VERIFY published ssm=${param} s3=${prefix}/lab-verification/site-${SITE_ID}.json"
}

wait_peer_verification() {
  local attempt status param="/nested-virt/lab/site-1/verification"
  for attempt in $(seq 1 120); do
    status=$(aws ssm get-parameter --region "$REGION" --name "$param" \
      --query Parameter.Value --output text 2>/dev/null | python3 -c \
      "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
    if [[ "$status" == GREEN ]]; then return 0; fi
    if [[ "$status" == RED ]]; then return 1; fi
    sleep 30
  done
  return 1
}

aggregate_lab() {
  local site0 site1 combined ts bucket prefix lab_status
  [[ "$SITE_ID" == "0" ]] || { lab_log "VERIFY aggregate skip non-coordinator site=${SITE_ID}"; return 0; }

  wait_peer_verification || check_fail peer-site-verification "site1-not-green"

  site0="$(cat "$VERIFY_JSON")"
  site1="$(aws ssm get-parameter --region "$REGION" \
    --name /nested-virt/lab/site-1/verification --query Parameter.Value --output text)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  combined=$(SITE0="$site0" SITE1="$site1" TS="$ts" python3 <<'PY'
import json, os
s0 = json.loads(os.environ["SITE0"])
s1 = json.loads(os.environ["SITE1"])
status = "GREEN" if s0.get("status") == "GREEN" and s1.get("status") == "GREEN" else "RED"
print(json.dumps({
    "status": status,
    "verified_at": os.environ["TS"],
    "sites": [s0, s1],
}))
PY
)

  lab_status=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['status'])" "$combined")
  echo "$combined" > "${LAB_STATE_DIR}/lab-verification-lab.json"
  echo "$lab_status" > "${LAB_STATE_DIR}/LAB_STATUS_LAB"

  aws ssm put-parameter --region "$REGION" --name /nested-virt/lab/verification \
    --value "$combined" --type String --overwrite

  bucket="$(lab_bootstrap_bucket)"
  prefix="$(lab_s3_prefix)"
  aws s3 cp "${LAB_STATE_DIR}/lab-verification-lab.json" \
    "${prefix}/lab-verification/lab.json" --region "$REGION"
  echo "$lab_status" | aws s3 cp - "${prefix}/lab-verification/lab.status" --region "$REGION"

  aws cloudwatch put-metric-data --region "$REGION" \
    --namespace NestedVirt/LabVerification \
    --metric-data "MetricName=LabStatus,Value=$([[ $lab_status == GREEN ]] && echo 1 || echo 0),Unit=Count"

  if [[ "$lab_status" != GREEN ]]; then
    lab_log "VERIFY LAB STATUS=RED"
    return 1
  fi
  lab_log "VERIFY LAB STATUS=GREEN definitive"
  return 0
}

record_site() {
  FAIL=0
  CHECKS=()
  CHECK_OK=()
  mkdir -p "$LAB_STATE_DIR"

  run_sanity_checks
  run_routing_and_internet
  write_site_json
  publish_site_record
  if (( FAIL )); then return 1; fi
  return 0
}

if (( RECORD )); then
  record_site || exit 1
fi

if (( AGGREGATE )); then
  aggregate_lab || exit 1
fi

if (( ! RECORD && ! AGGREGATE )); then
  record_site || exit 1
fi
