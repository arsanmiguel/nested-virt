#!/usr/bin/env bash
# Tag both instances with peer transport IPs and apply host routes via SSM.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "${ROOT}/config.env"
[[ -f "${ROOT}/config.local.env" ]] && source "${ROOT}/config.local.env"

ENV0="${ROOT}/.last-stack-site0.env"
ENV1="${ROOT}/.last-stack-site1.env"

if [[ ! -f "$ENV0" || ! -f "$ENV1" ]]; then
  echo "Missing ${ENV0} or ${ENV1}. Deploy both sites first."
  exit 1
fi
# shellcheck source=/dev/null
source "$ENV0"
SITE_0_INSTANCE_ID="$INSTANCE_ID"
SITE_0_TRANSPORT_IP="$TRANSPORT_IP"
# shellcheck source=/dev/null
source "$ENV1"
SITE_1_INSTANCE_ID="$INSTANCE_ID"
SITE_1_TRANSPORT_IP="$TRANSPORT_IP"

echo "Site 0: ${SITE_0_INSTANCE_ID} transport=${SITE_0_TRANSPORT_IP}"
echo "Site 1: ${SITE_1_INSTANCE_ID} transport=${SITE_1_TRANSPORT_IP}"

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
    --parameters 'commands=["aws s3 cp s3://nested-virt-bootstrap-'"${AWS_ACCOUNT_ID}"'/nested-virt/apply-peer-routes.sh /tmp/apply-peer-routes.sh && chmod +x /tmp/apply-peer-routes.sh && /tmp/apply-peer-routes.sh"]' \
    --query Command.CommandId --output text)
  sleep 12
  aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$iid" \
    --query StandardOutputContent --output text || true
}

apply_routes "$SITE_0_INSTANCE_ID"
apply_routes "$SITE_1_INSTANCE_ID"

{
  echo "SITE_0_INSTANCE_ID=${SITE_0_INSTANCE_ID}"
  echo "SITE_1_INSTANCE_ID=${SITE_1_INSTANCE_ID}"
  echo "SITE_0_TRANSPORT_IP=${SITE_0_TRANSPORT_IP}"
  echo "SITE_1_TRANSPORT_IP=${SITE_1_TRANSPORT_IP}"
} > "${ROOT}/sites.env"

echo "Wrote ${ROOT}/sites.env"
