#!/usr/bin/env bash
# Tag both instances with peer transport IPs and apply host routes via SSM.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"
source "${ROOT}/config.env"
[[ -f "${ROOT}/config.local.env" ]] && source "${ROOT}/config.local.env"
# shellcheck source=wait-deps.sh
source "${BIN}/wait-deps.sh"

ENV0="${ROOT}/.last-stack-site0.env"
ENV1="${ROOT}/.last-stack-site1.env"

if [[ ! -f "$ENV0" || ! -f "$ENV1" ]]; then
  echo "Missing ${ENV0} or ${ENV1}. Deploy both sites first."
  exit 1
fi
# shellcheck source=/dev/null
source "$ENV0"
SITE_0_INSTANCE_ID="$INSTANCE_ID"
# shellcheck source=/dev/null
source "$ENV1"
SITE_1_INSTANCE_ID="$INSTANCE_ID"

echo "Waiting for SSM on both metal hosts..."
wait_ssm_online "$SITE_0_INSTANCE_ID"
wait_ssm_online "$SITE_1_INSTANCE_ID"

get_transport_ip() {
  local iid="$1" site_env="$2"
  local cmd_id out
  if [[ -f "$site_env" ]]; then
    # shellcheck source=/dev/null
    source "$site_env"
    if [[ -n "${TRANSPORT_IP:-}" ]]; then
      echo "$TRANSPORT_IP"
      return 0
    fi
  fi
  cmd_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$iid" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["ip=$(ip -4 -o addr show dev kvm-host-nic1 2>/dev/null | awk \"{print \\$4}\" | cut -d/ -f1); if [ -z \"$ip\" ]; then ip=$(ip -4 -o addr show | awk \"/172\\.31\\.96\\./{print \\$4}\" | cut -d/ -f1 | head -1); fi; echo -n \"$ip\""]' \
    --query Command.CommandId --output text)
  sleep 10
  out=$(aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$iid" \
    --query StandardOutputContent --output text 2>/dev/null | tr -d '[:space:]')
  if [[ -z "$out" ]]; then
    echo "ERROR: could not read transport IP on ${iid}" >&2
    exit 1
  fi
  echo "$out"
}

SITE_0_TRANSPORT_IP=$(get_transport_ip "$SITE_0_INSTANCE_ID" "$ENV0")
SITE_1_TRANSPORT_IP=$(get_transport_ip "$SITE_1_INSTANCE_ID" "$ENV1")

echo "Site 0: ${SITE_0_INSTANCE_ID} transport=${SITE_0_TRANSPORT_IP} (kvm-host-nic1)"
echo "Site 1: ${SITE_1_INSTANCE_ID} transport=${SITE_1_TRANSPORT_IP} (kvm-host-nic1)"

aws ec2 create-tags --region "$AWS_REGION" --resources "$SITE_0_INSTANCE_ID" \
  --tags \
  "Key=PeerTransportEniIp,Value=${SITE_1_TRANSPORT_IP}" \
  "Key=PeerLabSupernet,Value=10.1.0.0/16"

aws ec2 create-tags --region "$AWS_REGION" --resources "$SITE_1_INSTANCE_ID" \
  --tags \
  "Key=PeerTransportEniIp,Value=${SITE_0_TRANSPORT_IP}" \
  "Key=PeerLabSupernet,Value=10.0.0.0/16"

apply_routes() {
  local iid="$1"
  echo "Applying peer routes on ${iid}..."
  local cmd_id
  cmd_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$iid" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"aws s3 cp s3://nested-virt-bootstrap-${AWS_ACCOUNT_ID}/nested-virt/fix-transport-routing.sh /tmp/fix-transport-routing.sh && chmod +x /tmp/fix-transport-routing.sh && /tmp/fix-transport-routing.sh && aws s3 cp s3://nested-virt-bootstrap-${AWS_ACCOUNT_ID}/nested-virt/setup-gre-tunnel.sh /tmp/setup-gre-tunnel.sh && aws s3 cp s3://nested-virt-bootstrap-${AWS_ACCOUNT_ID}/nested-virt/apply-peer-routes.sh /tmp/apply-peer-routes.sh && chmod +x /tmp/setup-gre-tunnel.sh /tmp/apply-peer-routes.sh && /tmp/apply-peer-routes.sh\"]" \
    --query Command.CommandId --output text)
  sleep 12
  aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$iid" \
    --query StandardOutputContent --output text || true
}

apply_routes "$SITE_0_INSTANCE_ID"
apply_routes "$SITE_1_INSTANCE_ID"

# Finish site 1 bootstrap if stuck in peer phase
cmd_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$SITE_1_INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["grep -q complete /var/lib/nested-virt/bootstrap-phase 2>/dev/null || /var/lib/nested-virt/bootstrap.sh"]' \
  --query Command.CommandId --output text)
sleep 30
aws ssm get-command-invocation --region "$AWS_REGION" \
  --command-id "$cmd_id" --instance-id "$SITE_1_INSTANCE_ID" \
  --query StandardOutputContent --output text | tail -8 || true

{
  echo "SITE_0_INSTANCE_ID=${SITE_0_INSTANCE_ID}"
  echo "SITE_1_INSTANCE_ID=${SITE_1_INSTANCE_ID}"
  echo "SITE_0_TRANSPORT_IP=${SITE_0_TRANSPORT_IP}"
  echo "SITE_1_TRANSPORT_IP=${SITE_1_TRANSPORT_IP}"
} > "${ROOT}/sites.env"

echo "Wrote ${ROOT}/sites.env"
