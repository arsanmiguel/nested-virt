#!/usr/bin/env bash
# Open Windows guest firewall (ICMP/WinRM) on both sites via WinRM from metal hosts.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"
source "${ROOT}/config.env"
[[ -f "${ROOT}/sites.env" ]] || { echo "Missing sites.env"; exit 1; }
# shellcheck source=/dev/null
source "${ROOT}/sites.env"

BOOTSTRAP_BUCKET="${BOOTSTRAP_BUCKET:-nested-virt-bootstrap-${AWS_ACCOUNT_ID}}"
S3_PREFIX="s3://${BOOTSTRAP_BUCKET}/nested-virt"

"${BIN}/upload-lab-scripts.sh"

apply_on() {
  local iid="$1" guest_ip="$2" label="$3"
  echo "--- ${label} guest ${guest_ip} ---"
  local cmd_id
  cmd_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$iid" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 180 \
    --parameters "commands=[\"aws s3 cp ${S3_PREFIX}/open-guest-firewall.ps1 /tmp/open-guest-firewall.ps1 && aws s3 cp ${S3_PREFIX}/apply-guest-firewall.sh /tmp/apply-guest-firewall.sh && chmod +x /tmp/apply-guest-firewall.sh && /tmp/apply-guest-firewall.sh ${guest_ip} /tmp/open-guest-firewall.ps1\"]" \
    --query Command.CommandId --output text)
  sleep 45
  aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$iid" \
    --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
}

apply_on "$SITE_0_INSTANCE_ID" "10.0.1.10" "Site 0"
apply_on "$SITE_1_INSTANCE_ID" "10.1.1.10" "Site 1"

echo ""
echo "Run: ./bin/invoke-routing-proof.sh --layer l1-guest"
