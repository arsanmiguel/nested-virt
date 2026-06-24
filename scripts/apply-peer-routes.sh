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
# Cloud-init policy routes target predicted ENI IPs; DHCP may differ.
for table_id in 101 102; do
  if ip route show table "$table_id" 2>/dev/null | grep -q "dev ${dev}"; then
    host=$(ip -4 -o addr show dev "$dev" | awk '{print $4}' | head -1 | cut -d/ -f1)
    gw=$(ip route show table "$table_id" | awk '/default via/ {print $3; exit}')
    peer="${peer_ip}"
    if [[ -n "$host" ]]; then
      while read -r rule; do
        from_ip=$(sed -n 's/.*from \([0-9.]*\).*/\1/p' <<< "$rule")
        if [[ -n "$from_ip" && "$from_ip" != "$host" ]]; then
          ip rule del from "$from_ip" lookup "$table_id" 2>/dev/null || true
        fi
      done < <(ip rule show | grep "lookup ${table_id}" || true)
      ip rule add from "$host" lookup "$table_id" pref 32764 2>/dev/null || true
    fi
    if [[ -n "$gw" && -n "$peer" ]]; then
      ip route replace "${peer}/32" via "$gw" dev "$dev" table "$table_id" onlink 2>/dev/null || true
      ip route replace "${peer_lab}" via "$peer" dev "$dev" onlink table "$table_id" 2>/dev/null || true
    fi
    break
  fi
done
ip route replace "${peer_ip}/32" via "${gw:-$(ip route show table 102 | awk '/default via/ {print $3; exit}')}" dev "$dev" onlink 2>/dev/null || true
ip route replace "$peer_lab" via "$peer_ip" dev "$dev" onlink 2>/dev/null || true
log "PHASE=PEER apply route ${peer_lab} via ${peer_ip}"

local_lab="10.${site_id}.0.0/16"
iptables -C FORWARD -s "$local_lab" -d "$peer_lab" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -s "$local_lab" -d "$peer_lab" -j ACCEPT
iptables -C FORWARD -s "$peer_lab" -d "$local_lab" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -s "$peer_lab" -d "$local_lab" -j ACCEPT
log "PHASE=PEER apply forward ${local_lab} <-> ${peer_lab}"
log "PHASE=PEER apply complete"
