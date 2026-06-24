#!/usr/bin/env bash
# Apply peer routes from instance tags (safe to re-run after configure-peer-routing.sh).
set -euo pipefail
TIMING_LOG=/var/log/amazon/launch-timing.log
log() { echo "$(date -Iseconds) $*" | tee -a "$TIMING_LOG"; }

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

peer_ip=$(imds_tag PeerTransportEniIp || true)
peer_lab=$(imds_tag PeerLabSupernet || true)
site_id=$(imds_tag SiteId || echo 0)

log "PHASE=PEER apply peer_ip=${peer_ip:-none} peer_lab=${peer_lab:-none} site_id=${site_id}"

if [[ -z "$peer_ip" || -z "$peer_lab" ]]; then
  log "PHASE=PEER apply skip missing tags"
  exit 0
fi

dev=kvm-host-nic1
ip route replace "$peer_lab" via "$peer_ip" dev "$dev"
log "PHASE=PEER apply route ${peer_lab} via ${peer_ip}"

local_lab="10.${site_id}.0.0/16"
iptables -C FORWARD -s "$local_lab" -d "$peer_lab" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -s "$local_lab" -d "$peer_lab" -j ACCEPT
iptables -C FORWARD -s "$peer_lab" -d "$local_lab" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -s "$peer_lab" -d "$local_lab" -j ACCEPT
log "PHASE=PEER apply forward ${local_lab} <-> ${peer_lab}"
log "PHASE=PEER apply complete"
