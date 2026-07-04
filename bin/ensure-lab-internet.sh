#!/usr/bin/env bash
# Upload and run internet/DNS ensure scripts on both metal hosts.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"
source "${ROOT}/config.env"
[[ -f "${ROOT}/config.local.env" ]] && source "${ROOT}/config.local.env"
[[ -f "${ROOT}/sites.env" ]] || { echo "Missing sites.env"; exit 1; }
# shellcheck source=/dev/null
source "${ROOT}/sites.env"
# shellcheck source=wait-deps.sh
source "${BIN}/wait-deps.sh"

BOOTSTRAP_BUCKET="${BOOTSTRAP_BUCKET:-nested-virt-bootstrap-${AWS_ACCOUNT_ID}}"
S3_PREFIX="s3://${BOOTSTRAP_BUCKET}/nested-virt"

SCRIPTS=(
  ensure-lab-guest-dns.ps1
  ensure-inner-guest-dns.sh
  internet-proof-on-host.sh
)

echo "=== Upload internet/DNS scripts ==="
for s in "${SCRIPTS[@]}"; do
  aws s3 cp "${ROOT}/scripts/${s}" "${S3_PREFIX}/${s}" --region "$AWS_REGION"
done

wait_ssm_online "$SITE_0_INSTANCE_ID"
wait_ssm_online "$SITE_1_INSTANCE_ID"

run_on_instance() {
  local iid="$1" site_id="$2" label="$3"
  echo "--- ${label} site ${site_id} ---"
  local cmd_id
  cmd_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$iid" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 600 \
    --parameters "commands=[\"aws s3 cp ${S3_PREFIX}/ensure-lab-guest-dns.ps1 /tmp/ensure-lab-guest-dns.ps1 && aws s3 cp ${S3_PREFIX}/ensure-inner-guest-dns.sh /tmp/ensure-inner-guest-dns.sh && aws s3 cp ${S3_PREFIX}/internet-proof-on-host.sh /tmp/internet-proof-on-host.sh && chmod +x /tmp/ensure-inner-guest-dns.sh /tmp/internet-proof-on-host.sh && /tmp/internet-proof-on-host.sh ${site_id}\"]" \
    --query Command.CommandId --output text)
  sleep 30
  aws ssm wait command-executed --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$iid" 2>/dev/null || true
  aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$iid" \
    --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
}

run_on_instance "$SITE_0_INSTANCE_ID" 0 "Site 0"
run_on_instance "$SITE_1_INSTANCE_ID" 1 "Site 1"

echo "Internet ensure complete on both sites."
