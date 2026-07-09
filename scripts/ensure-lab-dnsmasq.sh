#!/usr/bin/env bash
# Lab dnsmasq: DHCP-only on br-default. Never expose recursive DNS on the metal host.
# Mask system dnsmasq.service — apt install dnsmasq enables :53 by default.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

_is_lab_dnsmasq_pid() {
  local pid="$1" args
  args=$(ps -p "$pid" -o args= 2>/dev/null || true)
  [[ "$args" == *nested-virt-dnsmasq* || "$args" == *nested-virt-dnsmasq.conf* ]]
}

# Stop distro dnsmasq.service and any non-lab dnsmasq processes (never kill lab DHCP).
disable_system_dnsmasq() {
  systemctl stop dnsmasq 2>/dev/null || true
  systemctl disable dnsmasq 2>/dev/null || true
  systemctl mask dnsmasq 2>/dev/null || true
  local pid
  for pid in $(pgrep -x dnsmasq 2>/dev/null || true); do
    if _is_lab_dnsmasq_pid "$pid"; then continue; fi
    kill "$pid" 2>/dev/null || true
  done
}

# libvirt 'default' network runs its own dnsmasq on virbr0 — disable; lab uses br-default only.
disable_libvirt_default_dns() {
  command -v virsh >/dev/null 2>&1 || return 0
  virsh net-destroy default 2>/dev/null || true
  virsh net-autostart --disable default 2>/dev/null || true
}

# Call after libvirt install and on every boot (before/without starting lab DHCP).
harden_metal_dns() {
  disable_system_dnsmasq
  disable_libvirt_default_dns
}

# Exit 0 if no DNS listener on non-loopback addresses.
verify_no_public_dns() {
  local line addr
  if systemctl is-enabled dnsmasq 2>/dev/null | grep -qE 'enabled|static'; then
    echo "FAIL: dnsmasq.service is not masked/disabled ($(systemctl is-enabled dnsmasq 2>/dev/null))"
    return 1
  fi
  while read -r line; do
    if [[ -z "$line" ]]; then continue; fi
    # loopback / link-local stub resolver (systemd-resolved on 127.0.0.53%lo) is OK
    if echo "$line" | grep -qE '127\.0\.0\.[0-9]+%|127\.0\.0\.[0-9]+:53|\[::1\]:53'; then
      continue
    fi
    if echo "$line" | grep -q ':53'; then
      echo "FAIL: DNS listener: $line"
      return 1
    fi
  done < <(ss -ulnp 2>/dev/null | grep ':53' || true)
  while read -r line; do
    if [[ -z "$line" ]]; then continue; fi
    if echo "$line" | grep -qE '127\.0\.0\.[0-9]+%|127\.0\.0\.[0-9]+:53|\[::1\]:53'; then
      continue
    fi
    if echo "$line" | grep -q ':53'; then
      echo "FAIL: DNS listener (tcp): $line"
      return 1
    fi
  done < <(ss -tlnp 2>/dev/null | grep ':53' || true)
  echo "OK: no public DNS listeners"
  return 0
}

# site_id guest_mac — writes /etc/nested-virt-dnsmasq.conf and starts lab instance
start_lab_dnsmasq() {
  local site_id="${1:?site id}" mac="${2:?guest mac}"
  local conf=/etc/nested-virt-dnsmasq.conf
  local guest_ip gateway inner_mac inner_ip
  guest_ip="10.${site_id}.1.10"
  gateway="10.${site_id}.1.1"
  inner_mac="$(printf '52:54:00:20:%02x:20' "$((10#${site_id}))")"
  inner_ip="10.${site_id}.1.20"

  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y dnsmasq
  harden_metal_dns

  cat > "$conf" <<EOF
# Nested-virt lab: DHCP only on br-default (port=0 = no DNS listener).
# Do not enable recursion or bind to kvm-host-nic0.
port=0
bind-interfaces
interface=br-default
except-interface=kvm-host-nic0
except-interface=kvm-host-nic1
except-interface=kvm-host-nic2
no-resolv
dhcp-host=${mac},${guest_ip},set:nested-guest,infinite
dhcp-option=tag:nested-guest,3,${gateway}
# Lab dnsmasq is DHCP-only (port=0). Do not point DNS at gateway — nothing listens on :53.
dhcp-option=tag:nested-guest,6,1.1.1.1,1.0.0.1
dhcp-host=${inner_mac},${inner_ip},set:inner,infinite
dhcp-option=tag:inner,3,${gateway}
dhcp-option=tag:inner,6,1.1.1.1,1.0.0.1
EOF

  pkill -f "${conf}" 2>/dev/null || true
  nohup dnsmasq -C "$conf" --pid-file=/run/nested-virt-dnsmasq.pid \
    >> /var/log/nested-virt-provision.log 2>&1 &
  ip link set br-default up 2>/dev/null || true
  verify_no_public_dns || true
}
