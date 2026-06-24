#!/usr/bin/env bash
# Routing proof matrix — L0 transport ENI, L1 lab bridge gateways.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "${ROOT}/config.env"
[[ -f "${ROOT}/sites.env" ]] && source "${ROOT}/sites.env"

LAYER="${1:-all}"
if [[ "$LAYER" == "--layer" ]]; then
  LAYER="${2:-all}"
fi

: "${SITE_0_INSTANCE_ID:?Deploy sites and run configure-peer-routing.sh}"
: "${SITE_1_INSTANCE_ID:?}"

ssm_ping() {
  local src="$1" dst="$2" label="$3"
  echo "--- ${label}: ping ${dst} from ${src} ---"
  local cmd_id out
  cmd_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$src" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"ping -c 3 -W 2 ${dst}\"]" \
    --query Command.CommandId --output text)
  sleep 8
  out=$(aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$src" \
    --query StandardOutputContent --output text 2>/dev/null || echo FAIL)
  echo "$out"
  if echo "$out" | grep -q ' 0 received'; then
    echo "PHASE=ROUTE_FAIL layer=${label} src=${src} dst=${dst}"
    return 1
  fi
  echo "PHASE=ROUTE_OK layer=${label} dst=${dst}"
}

FAIL=0

if [[ "$LAYER" == "all" || "$LAYER" == "l0" ]]; then
  ssm_ping "$SITE_0_INSTANCE_ID" "$SITE_1_TRANSPORT_IP" "L0-transport" || FAIL=1
  ssm_ping "$SITE_1_INSTANCE_ID" "$SITE_0_TRANSPORT_IP" "L0-transport-reverse" || FAIL=1
fi

if [[ "$LAYER" == "all" || "$LAYER" == "l1" ]]; then
  ssm_ping "$SITE_0_INSTANCE_ID" "10.1.1.1" "L1-peer-lab-gateway" || FAIL=1
  ssm_ping "$SITE_1_INSTANCE_ID" "10.0.1.1" "L1-peer-lab-gateway-reverse" || FAIL=1
fi

if [[ "$LAYER" == "l2" ]]; then
  echo "L2 (nested Hyper-V guest) — manual until Windows guests are deployed."
  echo "See docs/hyperv-guest.md"
fi

if (( FAIL )); then
  echo "Routing proof FAILED."
  exit 1
fi
echo "Routing proof PASSED (${LAYER})."
