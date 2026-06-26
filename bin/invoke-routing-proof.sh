#!/usr/bin/env bash
# Routing proof matrix — L0 transport ENI, L1 lab gateways, L1 guests.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"
source "${ROOT}/config.env"
[[ -f "${ROOT}/sites.env" ]] && source "${ROOT}/sites.env"

LAYER="${1:-all}"
if [[ "$LAYER" == "--layer" ]]; then
  LAYER="${2:-all}"
fi

: "${SITE_0_INSTANCE_ID:?Deploy sites and run configure-peer-routing.sh}"
: "${SITE_1_INSTANCE_ID:?}"

ssm_run() {
  local src="$1" cmd="$2"
  local cmd_id out status
  cmd_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$src" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"${cmd}\"]" \
    --query Command.CommandId --output text)
  sleep 8
  status=$(aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$src" \
    --query Status --output text 2>/dev/null || echo Failed)
  out=$(aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$src" \
    --query StandardOutputContent --output text 2>/dev/null || echo FAIL)
  echo "$out"
  if [[ "$status" != Success ]] || [[ -z "$out" ]] || [[ "$out" == FAIL ]]; then
    return 1
  fi
  return 0
}

ssm_ping() {
  local src="$1" dst="$2" label="$3" bind_ip="${4:-}"
  echo "--- ${label}: ping ${dst} from ${src} (bind=${bind_ip:-default}) ---"
  local ping_cmd out
  if [[ -n "$bind_ip" ]]; then
    ping_cmd="ping -c 3 -W 2 -I ${bind_ip} ${dst}"
  else
    ping_cmd="ping -c 3 -W 2 ${dst}"
  fi
  if ! out=$(ssm_run "$src" "$ping_cmd"); then
    echo "PHASE=ROUTE_FAIL layer=${label} src=${src} dst=${dst} reason=ssm"
    return 1
  fi
  echo "$out"
  if echo "$out" | grep -qE ' 0 received|100% packet loss'; then
    echo "PHASE=ROUTE_FAIL layer=${label} src=${src} dst=${dst}"
    return 1
  fi
  echo "PHASE=ROUTE_OK layer=${label} dst=${dst}"
}

ssm_tcp() {
  local src="$1" dst="$2" port="$3" label="$4"
  echo "--- ${label}: tcp/${port} ${dst} from ${src} ---"
  local out tcp_cmd
  tcp_cmd="timeout 3 bash -c 'echo >/dev/tcp/${dst}/${port}' && echo TCP_OK || echo TCP_FAIL"
  if ! out=$(ssm_run "$src" "$tcp_cmd"); then
    echo "PHASE=ROUTE_FAIL layer=${label} src=${src} dst=${dst}:${port} reason=ssm"
    return 1
  fi
  echo "$out"
  if ! echo "$out" | grep -q TCP_OK; then
    echo "PHASE=ROUTE_FAIL layer=${label} src=${src} dst=${dst}:${port}"
    return 1
  fi
  echo "PHASE=ROUTE_OK layer=${label} dst=${dst}:${port}"
}

FAIL=0

if [[ "$LAYER" == "all" || "$LAYER" == "l0" ]]; then
  : "${SITE_0_TRANSPORT_IP:?Run configure-peer-routing.sh}"
  : "${SITE_1_TRANSPORT_IP:?Run configure-peer-routing.sh}"
  ssm_ping "$SITE_0_INSTANCE_ID" "$SITE_1_TRANSPORT_IP" "L0-transport" "$SITE_0_TRANSPORT_IP" || FAIL=1
  ssm_ping "$SITE_1_INSTANCE_ID" "$SITE_0_TRANSPORT_IP" "L0-transport-reverse" "$SITE_1_TRANSPORT_IP" || FAIL=1
fi

if [[ "$LAYER" == "all" || "$LAYER" == "l1" ]]; then
  ssm_ping "$SITE_0_INSTANCE_ID" "10.1.1.1" "L1-cross-site-gateway" || FAIL=1
  ssm_ping "$SITE_1_INSTANCE_ID" "10.0.1.1" "L1-cross-site-gateway-reverse" || FAIL=1
fi

if [[ "$LAYER" == "l1-cross" ]]; then
  ssm_ping "$SITE_0_INSTANCE_ID" "10.1.1.1" "L1-cross-site-gateway" || FAIL=1
  ssm_ping "$SITE_1_INSTANCE_ID" "10.0.1.1" "L1-cross-site-gateway-reverse" || FAIL=1
  ssm_ping "$SITE_0_INSTANCE_ID" "10.1.1.10" "L1-cross-site-guest" || FAIL=1
  ssm_ping "$SITE_1_INSTANCE_ID" "10.0.1.10" "L1-cross-site-guest-reverse" || FAIL=1
fi

if [[ "$LAYER" == "all" || "$LAYER" == "l1-local" ]]; then
  ssm_ping "$SITE_0_INSTANCE_ID" "10.0.1.1" "L1-local-lab-gateway" "$SITE_0_TRANSPORT_IP" || FAIL=1
  ssm_ping "$SITE_1_INSTANCE_ID" "10.1.1.1" "L1-local-lab-gateway" "$SITE_1_TRANSPORT_IP" || FAIL=1
fi

if [[ "$LAYER" == "all" || "$LAYER" == "l1-guest" ]]; then
  ssm_ping "$SITE_0_INSTANCE_ID" "10.0.1.10" "L1-guest-ping" || FAIL=1
  ssm_ping "$SITE_1_INSTANCE_ID" "10.1.1.10" "L1-guest-ping" || FAIL=1
fi

if [[ "$LAYER" == "l1-guest-winrm" ]]; then
  ssm_tcp "$SITE_0_INSTANCE_ID" "10.0.1.10" "5985" "L1-guest-winrm" || FAIL=1
  ssm_tcp "$SITE_1_INSTANCE_ID" "10.1.1.10" "5985" "L1-guest-winrm" || FAIL=1
fi

if [[ "$LAYER" == "all" || "$LAYER" == "l2" ]]; then
  ssm_ping "$SITE_0_INSTANCE_ID" "10.0.1.20" "L2-inner-local-site0" || FAIL=1
  ssm_ping "$SITE_1_INSTANCE_ID" "10.1.1.20" "L2-inner-local-site1" || FAIL=1
  ssm_ping "$SITE_0_INSTANCE_ID" "10.1.1.20" "L2-inner-cross" || FAIL=1
  ssm_ping "$SITE_1_INSTANCE_ID" "10.0.1.20" "L2-inner-cross-reverse" || FAIL=1
fi

if (( FAIL )); then
  echo "Routing proof FAILED."
  exit 1
fi
echo "Routing proof PASSED (${LAYER})."
