#!/usr/bin/env bash
# Rebuild inner Hyper-V VMs with public DNS + SSH password baked into the VHDX.
#
#   ./bin/refresh-inner-internet.sh         Start refresh on both sites (background via SSM).
#   ./bin/refresh-inner-internet.sh --wait          Block until both sites finish (~45–90 min each).
#   ./bin/refresh-inner-internet.sh --wait --site 1 Only site 1 (after site 0 completes).
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

WAIT=0
SITE_FILTER=both
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) WAIT=1; shift ;;
    --site) SITE_FILTER="${2:-both}"; shift 2 ;;
    --site=*) SITE_FILTER="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

BOOTSTRAP_BUCKET="${BOOTSTRAP_BUCKET:-nested-virt-bootstrap-${AWS_ACCOUNT_ID}}"
S3_PREFIX="s3://${BOOTSTRAP_BUCKET}/nested-virt"

"${BIN}/upload-lab-scripts.sh"

run_refresh() {
  local iid="$1" site_id="$2"
  echo "--- Refresh inner site ${site_id} (${iid}) ---" >&2
  aws ssm send-command --region "$AWS_REGION" --instance-ids "$iid" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 10800 \
    --parameters "commands=[\"aws s3 cp ${S3_PREFIX}/ensure-inner-guest-dns.sh /tmp/ensure-inner-guest-dns.sh --region ${AWS_REGION} && aws s3 cp ${S3_PREFIX}/prepare-ubuntu-inner-image.sh /tmp/prepare-ubuntu-inner-image.sh --region ${AWS_REGION} && aws s3 cp ${S3_PREFIX}/provision-ubuntu-inner-vm.ps1 /tmp/provision-ubuntu-inner-vm.ps1 --region ${AWS_REGION} && aws s3 cp ${S3_PREFIX}/deploy-inner-ubuntu-on-host.sh /tmp/deploy-inner-ubuntu-on-host.sh --region ${AWS_REGION} && aws s3 cp ${S3_PREFIX}/ensure-lab-guest-dns.ps1 /tmp/ensure-lab-guest-dns.ps1 --region ${AWS_REGION} && chmod +x /tmp/ensure-inner-guest-dns.sh /tmp/prepare-ubuntu-inner-image.sh /tmp/deploy-inner-ubuntu-on-host.sh && pkill -9 -f deploy-inner-ubuntu-on-host.sh 2>/dev/null || true; pkill -9 -f deploy-real-l2.sh 2>/dev/null || true; rm -f /var/lib/nested-virt/inner-deploy.lock; sleep 2; env REFRESH_INNER_VHDX=1 /tmp/ensure-inner-guest-dns.sh ${site_id}\"]" \
    --query Command.CommandId --output text
}

wait_refresh() {
  local iid="$1" site_id="$2" cmd_id="$3"
  local st=""
  echo "  waiting site ${site_id} (command ${cmd_id})..."
  while true; do
    st=$(aws ssm get-command-invocation --region "$AWS_REGION" \
      --command-id "$cmd_id" --instance-id "$iid" \
      --query Status --output text 2>/dev/null || echo Pending)
    echo "    $(date -u +%H:%M:%S) site ${site_id} status=${st}"
    case "$st" in
      Success|Failed|Cancelled|TimedOut|Cancelling) break ;;
    esac
    sleep 60
  done
  aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$iid" \
    --query '[Status,StandardOutputContent,StandardErrorContent]' --output text | tail -25
  [[ "$st" == Success ]]
}

wait_ssm_online "$SITE_0_INSTANCE_ID"
wait_ssm_online "$SITE_1_INSTANCE_ID"

if [[ "$WAIT" -eq 1 ]]; then
  fail=0
  if [[ "$SITE_FILTER" == "both" || "$SITE_FILTER" == "0" ]]; then
    cid0=$(run_refresh "$SITE_0_INSTANCE_ID" 0)
    wait_refresh "$SITE_0_INSTANCE_ID" 0 "$cid0" || fail=1
  fi
  if [[ "$SITE_FILTER" == "both" || "$SITE_FILTER" == "1" ]]; then
    cid1=$(run_refresh "$SITE_1_INSTANCE_ID" 1)
    wait_refresh "$SITE_1_INSTANCE_ID" 1 "$cid1" || fail=1
  fi
  [[ "$fail" -eq 0 ]] || { echo "Refresh FAILED." >&2; exit 1; }
  echo "Refresh complete."
else
  if [[ "$SITE_FILTER" == "both" || "$SITE_FILTER" == "0" ]]; then
    run_refresh "$SITE_0_INSTANCE_ID" 0
    sleep 15
  fi
  if [[ "$SITE_FILTER" == "both" || "$SITE_FILTER" == "1" ]]; then
    run_refresh "$SITE_1_INSTANCE_ID" 1
  fi
  echo "Refresh started in background. Use: ./bin/refresh-inner-internet.sh --wait"
fi
