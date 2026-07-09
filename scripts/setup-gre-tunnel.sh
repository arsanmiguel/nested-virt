#!/usr/bin/env bash
# Encapsulate peer lab supernet over transport ENIs (VPC fabric won't carry raw 10.x).
set -euo pipefail

TIMING_LOG=/var/log/amazon/launch-timing.log
TUN="${GRE_TUNNEL_NAME:-gre-peer}"

log() { echo "$(date -Iseconds) GRE $*" | tee -a "$TIMING_LOG"; }

imds_token() {
  curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}
imds_tag() {
  local key="$1" token
  token="$(imds_token)"
  curl -sf -H "X-aws-ec2-metadata-token: ${token}" \
    "http://169.254.169.254/latest/meta-data/tags/instance/${key}" 2>/dev/null
}

peer_ip="${PEER_TRANSPORT_IP:-$(imds_tag PeerTransportEniIp || true)}"
peer_lab="${PEER_LAB_SUPERNET:-$(imds_tag PeerLabSupernet || true)}"
site_id="${SITE_ID:-$(imds_tag SiteId || echo 0)}"
local_gw="10.${site_id}.1.1"

if [[ -z "$peer_ip" || -z "$peer_lab" ]]; then
  log "skip missing peer tags"
  exit 0
fi

dev=kvm-host-nic1
local_ip=$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1 || true)
if [[ -z "$local_ip" ]]; then
  log "fail no address on ${dev}"
  exit 1
fi

modprobe ip_gre 2>/dev/null || true

if ip link show "$TUN" >/dev/null 2>&1; then
  ip tunnel change "$TUN" mode gre local "$local_ip" remote "$peer_ip" ttl 64 2>/dev/null || true
else
  ip tunnel add "$TUN" mode gre local "$local_ip" remote "$peer_ip" ttl 64
fi
ip link set "$TUN" up
sysctl -w "net.ipv4.conf.${TUN}.rp_filter=0" >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true

gw=$(ip route show table 102 2>/dev/null | awk '/default via/ {print $3; exit}')
[[ -z "$gw" ]] && gw=$(ip route show table 101 2>/dev/null | awk '/default via/ {print $3; exit}')
if [[ -n "$gw" ]]; then
  ip route replace "${peer_ip}/32" via "$gw" dev "$dev"
  for table_id in 101 102; do
    ip route replace "${peer_ip}/32" via "$gw" dev "$dev" table "$table_id" onlink 2>/dev/null || true
    ip route replace "$peer_lab" dev "$TUN" src "$local_gw" table "$table_id" 2>/dev/null || true
  done
fi

# Drop stale direct lab route on transport ENI (non-encapsulated 10.x won't cross VPC).
ip route del "$peer_lab" via "$peer_ip" dev "$dev" onlink 2>/dev/null || true
ip route del "$peer_lab" via "$peer_ip" dev "$dev" 2>/dev/null || true

ip route replace "$peer_lab" dev "$TUN" src "$local_gw"
log "tunnel ${TUN} local=${local_ip} remote=${peer_ip} route=${peer_lab} src=${local_gw}"
