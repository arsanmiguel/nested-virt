#!/usr/bin/env bash
# Routing proof matrix on metal host — no laptop / no sites.env in repo required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=s3-lab-common.sh
source "${SCRIPT_DIR}/s3-lab-common.sh"

LAYER="${1:-all}"
if [[ "$LAYER" == "--layer" ]]; then
  LAYER="${2:-all}"
fi

SITE_ID="$(lab_site_id)"
STATE="${LAB_STATE_DIR}/sites.env"
[[ -f "$STATE" ]] || { lab_log "routing-proof missing ${STATE} — run coordinate-peer first"; exit 1; }
# shellcheck source=/dev/null
source "$STATE"

: "${SITE_0_INSTANCE_ID:?}"
: "${SITE_1_INSTANCE_ID:?}"
: "${SITE_0_TRANSPORT_IP:?}"
: "${SITE_1_TRANSPORT_IP:?}"

MY_IID="$(lab_instance_id)"
if [[ "$MY_IID" == "$SITE_0_INSTANCE_ID" ]]; then
  SRC_IID="$SITE_0_INSTANCE_ID"
  OTHER_IID="$SITE_1_INSTANCE_ID"
  MY_TIP="$SITE_0_TRANSPORT_IP"
  OTHER_TIP="$SITE_1_TRANSPORT_IP"
else
  SRC_IID="$SITE_1_INSTANCE_ID"
  OTHER_IID="$SITE_0_INSTANCE_ID"
  MY_TIP="$SITE_1_TRANSPORT_IP"
  OTHER_TIP="$SITE_0_TRANSPORT_IP"
fi

FAIL=0

ping_ok() {
  local dst="$1" bind="${2:-}" label="$3"
  echo "--- ${label}: ping ${dst} ---"
  if [[ -n "$bind" ]]; then
    ping -c 3 -W 2 -I "$bind" "$dst"
  else
    ping -c 3 -W 2 "$dst"
  fi
  echo "PHASE=ROUTE_OK layer=${label} dst=${dst}"
}

ssm_ping_from_peer() {
  local dst="$1" label="$2" bind="${3:-}"
  echo "--- ${label}: ping ${dst} via peer SSM ---"
  local cmd out
  if [[ -n "$bind" ]]; then
    cmd="ping -c 3 -W 2 -I ${bind} ${dst}"
  else
    cmd="ping -c 3 -W 2 ${dst}"
  fi
  out=$(ssm_run_instance "$OTHER_IID" "$cmd")
  echo "$out"
  if echo "$out" | grep -qE ' 0 received|100% packet loss'; then
    echo "PHASE=ROUTE_FAIL layer=${label}"
    return 1
  fi
  echo "PHASE=ROUTE_OK layer=${label} dst=${dst}"
}

# Site 0 runs cross-site probes via SSM; each site runs local probes.
if [[ "$SITE_ID" == "0" ]]; then
  if [[ "$LAYER" == "all" || "$LAYER" == "l0" ]]; then
    ping_ok "$SITE_1_TRANSPORT_IP" "$SITE_0_TRANSPORT_IP" "L0-transport" || FAIL=1
    ssm_ping_from_peer "$SITE_0_TRANSPORT_IP" "L0-transport-reverse" "$SITE_1_TRANSPORT_IP" || FAIL=1
  fi
  if [[ "$LAYER" == "all" || "$LAYER" == "l1" || "$LAYER" == "l1-cross" ]]; then
    ping_ok "10.1.1.1" "" "L1-cross-site-gateway" || FAIL=1
    ssm_ping_from_peer "10.0.1.1" "L1-cross-site-gateway-reverse" || FAIL=1
  fi
  if [[ "$LAYER" == "l1-cross" ]]; then
    ping_ok "10.1.1.10" "" "L1-cross-site-guest" || FAIL=1
    ssm_ping_from_peer "10.0.1.10" "L1-cross-site-guest-reverse" || FAIL=1
  fi
fi

if [[ "$LAYER" == "all" || "$LAYER" == "l1-local" ]]; then
  ping_ok "10.${SITE_ID}.1.1" "$MY_TIP" "L1-local-lab-gateway" || FAIL=1
fi

if [[ "$LAYER" == "all" || "$LAYER" == "l1-guest" ]]; then
  ping_ok "10.${SITE_ID}.1.10" "" "L1-guest-ping" || FAIL=1
fi

if [[ "$LAYER" == "all" || "$LAYER" == "l2" ]]; then
  ping_ok "10.${SITE_ID}.1.20" "" "L2-inner-local-site${SITE_ID}" || FAIL=1
  if [[ "$SITE_ID" == "0" ]]; then
    ping_ok "10.1.1.20" "" "L2-inner-cross" || FAIL=1
    ssm_ping_from_peer "10.0.1.20" "L2-inner-cross-reverse" || FAIL=1
  fi
fi

if [[ "$LAYER" == "all" || "$LAYER" == "internet" ]]; then
  s3_fetch_script internet-proof-on-host.sh /tmp/internet-proof-on-host.sh
  /tmp/internet-proof-on-host.sh "$SITE_ID" || FAIL=1
fi

if (( FAIL )); then
  lab_log "routing-proof FAILED layer=${LAYER} site=${SITE_ID}"
  exit 1
fi
lab_log "routing-proof PASSED layer=${LAYER} site=${SITE_ID}"
