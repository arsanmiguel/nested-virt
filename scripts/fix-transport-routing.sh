#!/usr/bin/env bash
# Fix cloud-init policy routes when DHCP IP != predicted ENI primary IP.
set -euo pipefail
dev=kvm-host-nic1
ip_cidr=$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | head -1 || true)
if [[ -z "$ip_cidr" ]]; then
  echo "no address on ${dev}"
  exit 0
fi
host="${ip_cidr%/*}"
for table_id in 101 102; do
  if ip route show table "$table_id" 2>/dev/null | grep -q "dev ${dev}"; then
    while read -r rule; do
      from_ip=$(sed -n 's/.*from \([0-9.]*\).*/\1/p' <<< "$rule")
      if [[ -n "$from_ip" && "$from_ip" != "$host" ]]; then
        ip rule del from "$from_ip" lookup "$table_id" 2>/dev/null || true
        echo "removed stale from=${from_ip} table=${table_id}"
      fi
    done < <(ip rule show | grep "lookup ${table_id}" || true)
    ip rule add from "$host" lookup "$table_id" pref 32764 2>/dev/null || true
    echo "policy from=${host} table=${table_id}"
    exit 0
  fi
done
echo "no policy table found for ${dev}"
