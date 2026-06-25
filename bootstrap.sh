#!/usr/bin/env bash
# Nested virt metal bootstrap — KVM host + site-aware lab bridges + peer routing.
set -euo pipefail

TIMING_LOG=/var/log/amazon/launch-timing.log
PHASE_FILE=/var/lib/nested-virt/bootstrap-phase
BOOTSTRAP_SCRIPT=/var/lib/nested-virt/bootstrap.sh
METRIC_NS=NestedVirt/Bootstrap

log() {
  local line
  line="$(date -Iseconds) $*"
  echo "$line" | tee -a "$TIMING_LOG"
}

on_err() {
  log "PHASE=FATAL line=${BASH_LINENO[0]} err=$*"
  exit 1
}
trap 'on_err "$BASH_COMMAND"' ERR

get_phase() {
  if [[ -f "$PHASE_FILE" ]]; then
    tr -d '[:space:]' < "$PHASE_FILE"
  else
    echo init
  fi
}

set_phase() {
  echo -n "$1" > "$PHASE_FILE"
}

register_reboot_resume() {
  cat > /etc/systemd/system/nested-virt-bootstrap.service <<EOF
[Unit]
Description=Nested virt metal bootstrap resume
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BOOTSTRAP_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable nested-virt-bootstrap.service
  log "PHASE=BOOTSTRAP_TASK registered nested-virt-bootstrap.service"
}

reboot_for_bootstrap() {
  local next="$1"
  log "PHASE=REBOOT scheduling next_phase=${next}"
  set_phase "$next"
  register_reboot_resume
  systemctl reboot
  exit 0
}

imds_token() {
  curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

imds_get() {
  local path="$1" token
  token="$(imds_token)"
  curl -sf -H "X-aws-ec2-metadata-token: ${token}" \
    "http://169.254.169.254/latest/meta-data/${path}"
}

imds_tag() {
  local key="$1" val token
  token="$(imds_token)"
  if val=$(curl -sf -H "X-aws-ec2-metadata-token: ${token}" \
    "http://169.254.169.254/latest/meta-data/tags/instance/${key}" 2>/dev/null); then
    echo "$val"
    return 0
  fi
  return 1
}

aws_retry() {
  local n=0
  until "$@"; do
    n=$((n + 1))
    if (( n >= 12 )); then return 1; fi
    sleep 10
  done
}

ensure_awscli() {
  command -v aws >/dev/null 2>&1 || {
    if grep -q '^ID=ubuntu' /etc/os-release 2>/dev/null; then
      apt-get install -y awscli || true
    else
      dnf install -y awscli
    fi
  }
}

init_vm_disk() {
  local dev=""
  for candidate in /dev/nvme1n1 /dev/xvdb /dev/sdb; do
    [[ -b "$candidate" ]] && dev="$candidate" && break
  done
  if [[ -z "$dev" ]]; then
    log "PHASE=DISK no data volume yet"
    return 0
  fi
  if ! blkid "$dev" >/dev/null 2>&1; then
    if grep -q '^ID=ubuntu' /etc/os-release 2>/dev/null; then
      mkfs.ext4 -F "$dev"
    else
      mkfs.xfs -f "$dev"
    fi
    log "PHASE=DISK formatted ${dev}"
  fi
  mkdir -p /var/lib/libvirt/images
  if ! mountpoint -q /var/lib/libvirt/images; then
    grep -q "$dev" /etc/fstab || echo "$dev /var/lib/libvirt/images ext4 defaults,nofail 0 2" >> /etc/fstab
    mount /var/lib/libvirt/images
    log "PHASE=DISK mounted ${dev} -> /var/lib/libvirt/images"
  fi
}

install_features() {
  log 'PHASE=FEATURES begin'
  if grep -q '^ID=ubuntu' /etc/os-release 2>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y \
      qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
      bridge-utils iptables-persistent chrony curl \
      libguestfs-tools virt-top python3
    systemctl enable --now libvirtd chrony
    if ! command -v aws >/dev/null 2>&1; then
      apt-get install -y awscli || true
      if ! command -v aws >/dev/null 2>&1; then
        curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
        unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
      fi
    fi
  else
    dnf install -y \
      qemu-kvm libvirt libvirt-daemon-config-network virt-install \
      bridge-utils iptables-services \
      amazon-cloudwatch-agent awscli chrony \
      libguestfs-tools virt-top || {
        log 'PHASE=FEATURES ERROR AL2023 lacks libvirt/qemu-kvm in repos — use Ubuntu host AMI'
        exit 1
      }
    systemctl enable --now libvirtd chronyd
  fi
  log 'PHASE=FEATURES done'
}

configure_extra_nics() {
  local expected="${1:-2}" deadline count i name cur mac devno token
  log "PHASE=NIC begin expected_extra=${expected}"
  deadline=$(( $(date +%s) + 8 * 60 ))
  while (( $(date +%s) < deadline )); do
    count=$(ip -o link show | awk -F': ' '$2 !~ /^(lo|virbr|br-|vnet|docker)/ {print $2}' | wc -l)
    if (( count >= 1 + expected )); then break; fi
    sleep 15
  done
  if (( count < 1 + expected )); then
    log "PHASE=NIC expected $((1 + expected)) interfaces found ${count}"
    return 1
  fi

  token="$(imds_token)"
  mapfile -t macs < <(curl -sf -H "X-aws-ec2-metadata-token: ${token}" \
    "http://169.254.169.254/latest/meta-data/network/interfaces/macs/" | tr -d '/')
  for mac in "${macs[@]}"; do
    devno=$(curl -sf -H "X-aws-ec2-metadata-token: ${token}" \
      "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${mac}/device-number")
    cur=$(ip -o link show | awk -v m="${mac}" 'BEGIN{
      gsub(":","",m); m=tolower(m)
    } {
      split($2, a, ":"); iface=a[2]
      for (i = 3; i <= NF; i++) {
        gsub(":","",$i)
        if (tolower($i) == m) { print iface; exit }
      }
    }')
    [[ -z "$cur" ]] && continue
    name="kvm-host-nic${devno}"
    if [[ "$cur" != "$name" ]]; then
      ip link set "$cur" down || true
      ip link set "$cur" name "$name" || log "PHASE=NIC rename keep ${cur}"
      ip link set "$name" up || true
      log "PHASE=NIC rename ${cur} -> ${name} (device-number=${devno} mac=${mac})"
    fi
  done

  for i in $(seq 1 "$expected"); do
    name="kvm-host-nic${i}"
    while ip route show default dev "$name" 2>/dev/null | grep -q .; do
      ip route del default dev "$name" || true
      log "PHASE=NIC removed default route iface=${name}"
    done
  done
  fix_transport_nic_routing
  log 'PHASE=NIC complete'
}

fix_transport_nic_routing() {
  local dev=kvm-host-nic1 ip_cidr host table_id rule from_ip
  ip_cidr=$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | head -1 || true)
  if [[ -z "$ip_cidr" ]]; then
    log "PHASE=NIC transport routing skip no address on ${dev}"
    return 0
  fi
  host="${ip_cidr%/*}"
  for table_id in 101 102; do
    if ip route show table "$table_id" 2>/dev/null | grep -q "dev ${dev}"; then
      while read -r rule; do
        from_ip=$(sed -n 's/.*from \([0-9.]*\).*/\1/p' <<< "$rule")
        if [[ -n "$from_ip" && "$from_ip" != "$host" ]]; then
          ip rule del from "$from_ip" lookup "$table_id" 2>/dev/null || true
          log "PHASE=NIC removed stale policy from=${from_ip} table=${table_id}"
        fi
      done < <(ip rule show | grep "lookup ${table_id}" || true)
      if ! ip rule show | grep -q "from ${host} lookup ${table_id}"; then
        ip rule add from "$host" lookup "$table_id" pref 32764
        log "PHASE=NIC policy route from=${host} table=${table_id}"
      fi
      return 0
    fi
  done
  log "PHASE=NIC transport routing warn no policy table for ${dev}"
}

enable_nested_kvm() {
  log 'PHASE=NESTED begin'
  local kvm_mod nested_param
  if grep -q Intel /proc/cpuinfo; then
    kvm_mod=kvm_intel
    nested_param=nested
  else
    kvm_mod=kvm_amd
    nested_param=nested
  fi
  modprobe "$kvm_mod" || true
  echo "options ${kvm_mod} ${nested_param}=1" > /etc/modprobe.d/kvm-nested.conf
  if lsmod | grep -q "^${kvm_mod}"; then
    modprobe -r "${kvm_mod}" 2>/dev/null || true
    modprobe kvm 2>/dev/null || true
    modprobe "${kvm_mod}"
  fi
  local nested_val
  nested_val=$(cat "/sys/module/${kvm_mod}/parameters/${nested_param}" 2>/dev/null || echo unknown)
  log "PHASE=NESTED module=${kvm_mod} ${nested_param}=${nested_val}"
  if [[ "$nested_val" != "Y" && "$nested_val" != "1" ]]; then
    log "PHASE=NESTED WARN nested virt not enabled"
  fi
  if [[ -c /dev/kvm ]]; then
    log 'PHASE=NESTED /dev/kvm present'
  else
    log 'PHASE=NESTED ERROR /dev/kvm missing'
    return 1
  fi
  log 'PHASE=NESTED complete'
}

site_octet() {
  local site_id="${1:-0}"
  echo "$site_id"
}

ensure_bridge() {
  local name="$1" uplink="${2:-}"
  if ip link show "$name" >/dev/null 2>&1; then
    log "PHASE=KVM bridge exists name=${name}"
    return 0
  fi
  ip link add name "$name" type bridge
  ip link set "$name" up
  if [[ -n "$uplink" ]]; then
    ip link set "$uplink" master "$name" 2>/dev/null || true
    ip link set "$uplink" up
    log "PHASE=KVM bridge created name=${name} uplink=${uplink}"
  else
    log "PHASE=KVM bridge created name=${name} type=internal"
  fi
}

bridge_ip() {
  local br="$1" ip="$2" prefix="$3"
  if ip -4 addr show dev "$br" | grep -q "${ip}/"; then
    log "PHASE=KVM ip exists bridge=${br} ip=${ip}"
    return 0
  fi
  ip addr add "${ip}/${prefix}" dev "$br"
  log "PHASE=KVM ip assigned bridge=${br} ip=${ip}/${prefix}"
}

configure_kvm_networking() {
  local site_id site oct
  site_id=$(imds_tag SiteId 2>/dev/null || echo 0)
  site="${site_id:-0}"
  oct="$(site_octet "$site")"
  log "PHASE=KVM begin site_id=${site} lab_octet=${oct}"

  modprobe br_netfilter || true
  sysctl -w net.ipv4.ip_forward=1
  grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.d/99-nested-virt.conf 2>/dev/null || \
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.d/99-nested-virt.conf

  for sw in default backup monitoring heartbeat production dev qa; do
    ensure_bridge "br-${sw}"
  done
  ensure_bridge "br-cluster" "kvm-host-nic2"

  bridge_ip br-default "10.${oct}.1.1" 24
  bridge_ip br-backup "10.${oct}.100.1" 24
  bridge_ip br-monitoring "10.${oct}.101.1" 24
  bridge_ip br-heartbeat "10.${oct}.102.1" 24
  bridge_ip br-cluster "10.${oct}.250.1" 24
  bridge_ip br-production "10.${oct}.16.1" 20
  bridge_ip br-dev "10.${oct}.64.1" 19
  bridge_ip br-qa "10.${oct}.96.1" 22

  local nat_prefix="10.${oct}.1.0/24"
  if ! iptables -t nat -C POSTROUTING -s "$nat_prefix" -o kvm-host-nic0 -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "$nat_prefix" -o kvm-host-nic0 -j MASQUERADE
    log "PHASE=KVM nat created prefix=${nat_prefix}"
  fi
  service iptables save 2>/dev/null || true
  log 'PHASE=KVM complete'
}

configure_peer_routes() {
  local peer_ip peer_lab site_id oct dev
  fix_transport_nic_routing
  peer_ip=$(imds_tag PeerTransportEniIp 2>/dev/null || true)
  peer_lab=$(imds_tag PeerLabSupernet 2>/dev/null || true)
  log "PHASE=PEER begin peer_ip=${peer_ip:-none} peer_lab=${peer_lab:-none}"
  if [[ -z "$peer_ip" || -z "$peer_lab" ]]; then
    log 'PHASE=PEER skip no peer tags'
    return 0
  fi
  dev=kvm-host-nic1
  local gw host
  host=$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1 || true)
  gw=$(ip route show table 102 2>/dev/null | awk '/default via/ {print $3; exit}')
  [[ -z "$gw" ]] && gw=$(ip route show table 101 2>/dev/null | awk '/default via/ {print $3; exit}')
  if [[ -n "$gw" ]]; then
    ip route replace "${peer_ip}/32" via "$gw" dev "$dev"
    log "PHASE=PEER host route ${peer_ip}/32 via ${gw} dev ${dev}"
  fi
  if ! ip route show "$peer_lab" 2>/dev/null | grep -q "$peer_ip"; then
    ip route replace "$peer_lab" via "$peer_ip" dev "$dev" onlink
    log "PHASE=PEER route added ${peer_lab} via ${peer_ip} dev ${dev} onlink"
  fi
  site_id=$(imds_tag SiteId 2>/dev/null || echo 0)
  oct="$(site_octet "${site_id:-0}")"
  local local_lab="10.${oct}.0.0/16"
  if ! iptables -C FORWARD -s "$local_lab" -d "$peer_lab" -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -s "$local_lab" -d "$peer_lab" -j ACCEPT
    iptables -A FORWARD -s "$peer_lab" -d "$local_lab" -j ACCEPT
    log "PHASE=PEER forward rules ${local_lab} <-> ${peer_lab}"
  fi
  log 'PHASE=PEER complete'
}

validate_nested_stack() {
  log 'PHASE=VALIDATE begin'
  if command -v virt-host-validate >/dev/null 2>&1; then
    virt-host-validate qemu 2>&1 | tee -a "$TIMING_LOG" || log 'PHASE=VALIDATE virt-host-validate warnings'
  fi
  virsh net-list --all 2>&1 | tee -a "$TIMING_LOG" || true
  ip -4 route show table main | tee -a "$TIMING_LOG" || true
  log 'PHASE=VALIDATE complete'
}

publish_build_timing() {
  local region iid itype complete_utc duration_sec instance_name
  region="$(imds_get placement/region)"
  iid="$(imds_get instance-id)"
  itype="$(imds_get instance-type)"
  complete_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  duration_sec=0
  aws_retry aws cloudwatch put-metric-data --region "$region" --namespace "$METRIC_NS" --metric-data \
    "MetricName=BootstrapComplete,Dimensions=[{Name=InstanceId,Value=${iid}}],Value=1,Unit=Count" || \
    log 'PHASE=CW_TIMING metric warn'
  log "PHASE=COMPLETE instance_id=${iid} instance_type=${itype} complete_utc=${complete_utc}"
}

run_phase() {
  local phase="$1" region extra_nics

  case "$phase" in
    init)
      init_vm_disk
      install_features
      extra_nics=$(imds_tag ExtraHostNicCount 2>/dev/null || echo 2)
      configure_extra_nics "$extra_nics"
      enable_nested_kvm
      set_phase nested
      ;;
    nested)
      if grep -q '^ID=ubuntu' /etc/os-release 2>/dev/null; then
        apt-get update -y || true
        apt-get upgrade -y || true
      else
        dnf update -y --security || true
        if needs-restarting -r >/dev/null 2>&1; then
          reboot_for_bootstrap nested
        fi
      fi
      configure_kvm_networking
      set_phase peer
      ;;
    peer)
      configure_peer_routes
      validate_nested_stack
      publish_build_timing
      set_phase complete
      systemctl disable nested-virt-bootstrap.service 2>/dev/null || true
      log 'PHASE=BOOTSTRAP finished'
      ;;
    complete)
      log 'PHASE=BOOTSTRAP already complete'
      systemctl disable nested-virt-bootstrap.service 2>/dev/null || true
      exit 0
      ;;
    *)
      log "PHASE=BOOTSTRAP unknown phase=${phase}"
      exit 1
      ;;
  esac
}

main() {
  mkdir -p /var/log/amazon /var/lib/nested-virt
  chmod +x "$BOOTSTRAP_SCRIPT" 2>/dev/null || true

  local phase region
  phase="$(get_phase)"
  log "PHASE=START nested-virt bootstrap pid=$$ phase=${phase}"

  ensure_awscli
  region="$(imds_get placement/region)"
  log "PHASE=REGION region=${region}"

  while [[ "$phase" != complete ]]; do
    run_phase "$phase" "$region"
    phase="$(get_phase)"
  done
}

main "$@"
