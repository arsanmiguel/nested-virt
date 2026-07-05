#!/usr/bin/env bash
# Discover both lab metal hosts, tag peer transport IPs, apply GRE/routes (no laptop).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=s3-lab-common.sh
source "${SCRIPT_DIR}/s3-lab-common.sh"

lab_log "coordinate-peer begin site=$(lab_site_id)"

ensure_awscli
region="$(lab_region)"
my_iid="$(lab_instance_id)"
my_site="$(lab_site_id)"

# Only site 0 coordinates tagging to avoid races.
if [[ "$my_site" != "0" ]]; then
  lab_log "coordinate-peer skip non-coordinator site=${my_site}"
  exit 0
fi

discover() {
  aws ec2 describe-instances --region "$region" \
    --filters "Name=tag:Project,Values=nested-virt" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].{Id:InstanceId,Site:Tags[?Key==`SiteId`]|[0].Value}' \
    --output json
}

SITE0_ID="" SITE1_ID="" SITE0_TIP="" SITE1_TIP=""
for attempt in $(seq 1 60); do
  mapfile -t rows < <(discover | python3 -c "
import json,sys
for i in json.load(sys.stdin):
    s = i.get('Site') or '0'
    print(f\"{s}\t{i['Id']}\")
")
  for row in "${rows[@]}"; do
    [[ -z "$row" ]] && continue
    sid="${row%%$'\t'*}"
    iid="${row#*$'\t'}"
    [[ "$sid" == "0" ]] && SITE0_ID="$iid"
    [[ "$sid" == "1" ]] && SITE1_ID="$iid"
  done
  if [[ -n "$SITE0_ID" && -n "$SITE1_ID" ]]; then
    wait_ssm_online_instance "$SITE0_ID" || true
    wait_ssm_online_instance "$SITE1_ID" || true
    if [[ "$my_iid" == "$SITE0_ID" ]]; then
      SITE0_TIP="$(transport_ip_on_host)"
    else
      SITE0_TIP=$(ssm_run_instance "$SITE0_ID" \
        "ip -4 -o addr show dev kvm-host-nic1 2>/dev/null | awk '{print \$4}' | cut -d/ -f1")
      SITE0_TIP=$(echo "$SITE0_TIP" | tr -d '[:space:]')
    fi
    if [[ "$my_iid" == "$SITE1_ID" ]]; then
      SITE1_TIP="$(transport_ip_on_host)"
    else
      SITE1_TIP=$(ssm_run_instance "$SITE1_ID" \
        "ip -4 -o addr show dev kvm-host-nic1 2>/dev/null | awk '{print \$4}' | cut -d/ -f1")
      SITE1_TIP=$(echo "$SITE1_TIP" | tr -d '[:space:]')
    fi
    if [[ -n "$SITE0_TIP" && -n "$SITE1_TIP" ]]; then
      break
    fi
  fi
  lab_log "coordinate-peer wait attempt=${attempt}/60 site0=${SITE0_ID:-none} site1=${SITE1_ID:-none}"
  sleep 30
done

[[ -n "$SITE0_ID" && -n "$SITE1_ID" && -n "$SITE0_TIP" && -n "$SITE1_TIP" ]] || {
  lab_log "coordinate-peer FAIL could not discover both sites"
  exit 1
}

lab_log "coordinate-peer site0=${SITE0_ID} tip=${SITE0_TIP} site1=${SITE1_ID} tip=${SITE1_TIP}"

aws ec2 create-tags --region "$region" --resources "$SITE0_ID" \
  --tags "Key=PeerTransportEniIp,Value=${SITE1_TIP}" "Key=PeerLabSupernet,Value=10.1.0.0/16"
aws ec2 create-tags --region "$region" --resources "$SITE1_ID" \
  --tags "Key=PeerTransportEniIp,Value=${SITE0_TIP}" "Key=PeerLabSupernet,Value=10.0.0.0/16"

apply_on() {
  local iid="$1"
  local prefix
  prefix="$(lab_s3_prefix)"
  ssm_run_instance "$iid" \
    "aws s3 cp ${prefix}/fix-transport-routing.sh /tmp/fix-transport-routing.sh --region ${region} && chmod +x /tmp/fix-transport-routing.sh && /tmp/fix-transport-routing.sh && aws s3 cp ${prefix}/setup-gre-tunnel.sh /tmp/setup-gre-tunnel.sh --region ${region} && aws s3 cp ${prefix}/apply-peer-routes.sh /tmp/apply-peer-routes.sh --region ${region} && chmod +x /tmp/setup-gre-tunnel.sh /tmp/apply-peer-routes.sh && /tmp/apply-peer-routes.sh && grep -q complete /var/lib/nested-virt/bootstrap-phase 2>/dev/null || /var/lib/nested-virt/bootstrap.sh"
}

apply_on "$SITE0_ID"
apply_on "$SITE1_ID"

mkdir -p "$LAB_STATE_DIR"
{
  echo "SITE_0_INSTANCE_ID=${SITE0_ID}"
  echo "SITE_1_INSTANCE_ID=${SITE1_ID}"
  echo "SITE_0_TRANSPORT_IP=${SITE0_TIP}"
  echo "SITE_1_TRANSPORT_IP=${SITE1_TIP}"
} > "${LAB_STATE_DIR}/sites.env"

if [[ "$SITE1_ID" != "$my_iid" ]]; then
  sites_b64=$(base64 -w0 "${LAB_STATE_DIR}/sites.env")
  ssm_run_instance "$SITE1_ID" "mkdir -p ${LAB_STATE_DIR} && echo ${sites_b64} | base64 -d > ${LAB_STATE_DIR}/sites.env"
fi

lab_log "coordinate-peer OK wrote ${LAB_STATE_DIR}/sites.env"
