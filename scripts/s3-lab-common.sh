#!/usr/bin/env bash
# Shared helpers for on-instance lab scripts (S3 bootstrap prefix, IMDS tags).
set -euo pipefail

S3_LAB_COMMON_LOADED=1

LAB_STATE_DIR="${LAB_STATE_DIR:-/var/lib/nested-virt}"
TIMING_LOG="${TIMING_LOG:-/var/log/amazon/launch-timing.log}"

lab_log() { echo "$(date -Iseconds) LAB $*" | tee -a "$TIMING_LOG"; }

imds_token() {
  curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

imds_get() {
  local path="$1" token
  token="$(imds_token)"
  curl -sf -H "X-aws-ec2-metadata-token: ${token}" \
    "http://169.254.169.254/latest/meta-data/${path}"
}

imds_tag() {
  local key="$1" token
  token="$(imds_token)"
  curl -sf -H "X-aws-ec2-metadata-token: ${token}" \
    "http://169.254.169.254/latest/meta-data/tags/instance/${key}" 2>/dev/null || true
}

lab_account_id() {
  curl -sf -H "X-aws-ec2-metadata-token: $(imds_token)" \
    http://169.254.169.254/latest/dynamic/instance-identity/document \
    | sed -n 's/.*"accountId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

lab_region() {
  imds_get placement/region
}

lab_instance_id() {
  imds_get instance-id
}

lab_site_id() {
  imds_tag SiteId || echo 0
}

lab_bootstrap_bucket() {
  local tag
  tag="$(imds_tag BootstrapBucket 2>/dev/null || true)"
  if [[ -n "$tag" ]]; then
    echo "$tag"
    return 0
  fi
  echo "nested-virt-bootstrap-$(lab_account_id)"
}

lab_s3_prefix() {
  echo "s3://$(lab_bootstrap_bucket)/nested-virt"
}

ensure_awscli() {
  if command -v aws >/dev/null 2>&1; then return 0; fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y awscli curl >/dev/null 2>&1 || apt-get install -y awscli >/dev/null 2>&1 || true
}

s3_fetch_script() {
  local name="$1" dest="${2:-/tmp/${name}}"
  ensure_awscli
  aws s3 cp "$(lab_s3_prefix)/${name}" "$dest" --region "$(lab_region)"
  chmod +x "$dest" 2>/dev/null || true
  echo "$dest"
}

wait_ssm_online_instance() {
  local iid="$1" attempt status region
  region="$(lab_region)"
  for attempt in $(seq 1 48); do
    status=$(aws ssm describe-instance-information --region "$region" \
      --filters "Key=InstanceIds,Values=${iid}" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)
    if [[ "$status" == "Online" ]]; then return 0; fi
    sleep 15
  done
  return 1
}

ssm_run_instance() {
  local iid="$1" remote_cmd="$2" region cmd_id params
  region="$(lab_region)"
  wait_ssm_online_instance "$iid"
  params=$(REMOTE_CMD="$remote_cmd" python3 -c 'import json, os; print(json.dumps({"commands": [os.environ["REMOTE_CMD"]]}))')
  cmd_id=$(aws ssm send-command --region "$region" --instance-ids "$iid" \
    --document-name AWS-RunShellScript \
    --parameters "$params" \
    --query Command.CommandId --output text)
  sleep 10
  aws ssm get-command-invocation --region "$region" \
    --command-id "$cmd_id" --instance-id "$iid" \
    --query StandardOutputContent --output text 2>/dev/null || true
}

discover_lab_instances_json() {
  local region
  region="$(lab_region)"
  aws ec2 describe-instances --region "$region" \
    --filters "Name=tag:Project,Values=nested-virt" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].{Id:InstanceId,Site:Tags[?Key==`SiteId`]|[0].Value,Az:Placement.AvailabilityZone}' \
    --output json
}

transport_ip_on_host() {
  ip -4 -o addr show dev kvm-host-nic1 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1 || true
}
