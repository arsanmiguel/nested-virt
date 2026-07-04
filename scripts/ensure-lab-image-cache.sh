#!/usr/bin/env bash
# Lab image cache on /var/lib/libvirt/images (data EBS). ISO lives in S3; host keeps a local copy.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

CACHE_DIR="${LAB_IMAGE_CACHE_DIR:-/var/lib/libvirt/images}"
CACHE_MARKER="${CACHE_DIR}/.nested-virt-cache-v1"
WIN_ISO="${CACHE_DIR}/Win2022.iso"
VIRTIO_ISO="${CACHE_DIR}/virtio-win.iso"
WIN_ISO_MIN_BYTES="${WIN_ISO_MIN_BYTES:-5000000000}"
VIRTIO_ISO_MIN_BYTES="${VIRTIO_ISO_MIN_BYTES:-700000000}"

icache_log() { echo "$(date -Iseconds) IMAGE_CACHE $*"; }

bootstrap_bucket() {
  local account region
  account=$(curl -sf -H "X-aws-ec2-metadata-token: $(curl -sf -X PUT \
    http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
    http://169.254.169.254/latest/dynamic/instance-identity/document 2>/dev/null | \
    sed -n 's/.*"accountId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)
  region=$(curl -sf -H "X-aws-ec2-metadata-token: $(curl -sf -X PUT \
    http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
    http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
  echo "nested-virt-bootstrap-${account}|${region}"
}

default_windows_iso_s3_uri() {
  local bucket region
  IFS='|' read -r bucket region < <(bootstrap_bucket)
  [[ -n "$bucket" && -n "$region" ]] || return 1
  echo "s3://${bucket}/nested-virt/Win2022.iso|${region}"
}

s3_object_size() {
  local uri="$1" region="$2" bucket key
  bucket="${uri#s3://}"; bucket="${bucket%%/*}"
  key="${uri#s3://${bucket}/}"
  aws s3api head-object --region "$region" --bucket "$bucket" --key "$key" \
    --query ContentLength --output text 2>/dev/null || echo ""
}

local_file_ok() {
  local path="$1" min_bytes="$2" want_bytes="${3:-}"
  [[ -f "$path" ]] || return 1
  local size
  size=$(stat -c%s "$path" 2>/dev/null || echo 0)
  [[ "$size" -ge "$min_bytes" ]] || return 1
  if [[ -n "$want_bytes" && "$want_bytes" != "None" && "$size" == "$want_bytes" ]]; then
    return 0
  fi
  [[ -z "$want_bytes" || "$want_bytes" == "None" ]]
}

ensure_s3_object_cached() {
  local label="$1" uri="$2" region="$3" dest="$4" min_bytes="$5"
  local remote_size tmp
  remote_size=$(s3_object_size "$uri" "$region")
  if local_file_ok "$dest" "$min_bytes" "$remote_size"; then
    icache_log "${label} cache hit ${dest} size=$(stat -c%s "$dest")"
    return 0
  fi
  mkdir -p "$CACHE_DIR"
  tmp="${dest}.partial.$$"
  icache_log "${label} prefetch from ${uri}"
  if ! aws s3 cp "$uri" "$tmp" --region "$region"; then
    rm -f "$tmp"
    icache_log "ERROR ${label} s3 prefetch failed ${uri}"
    return 1
  fi
  if ! local_file_ok "$tmp" "$min_bytes"; then
    rm -f "$tmp"
    icache_log "ERROR ${label} s3 object too small"
    return 1
  fi
  mv -f "$tmp" "$dest"
  chmod 644 "$dest" 2>/dev/null || true
  icache_log "${label} ready size=$(stat -c%s "$dest")"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$CACHE_MARKER" 2>/dev/null || true
}

ensure_windows_iso() {
  local uri="${WINDOWS_ISO_S3_URI:-}" region=""
  if [[ -z "$uri" ]]; then
    local default_info
    default_info=$(default_windows_iso_s3_uri) || {
      icache_log "windows iso: no WINDOWS_ISO_S3_URI and no bootstrap bucket"
      return 1
    }
    uri="${default_info%%|*}"
    region="${default_info##*|}"
  else
    region="${AWS_REGION:-$(bootstrap_bucket | cut -d'|' -f2)}"
  fi
  ensure_s3_object_cached "windows" "$uri" "$region" "$WIN_ISO" "$WIN_ISO_MIN_BYTES"
}

ensure_virtio_iso() {
  local uri region bucket url tmp
  IFS='|' read -r bucket region < <(bootstrap_bucket)
  uri="${VIRTIO_ISO_S3_URI:-s3://${bucket}/nested-virt/virtio-win.iso}"
  region="${AWS_REGION:-$region}"
  if ensure_s3_object_cached "virtio" "$uri" "$region" "$VIRTIO_ISO" "$VIRTIO_ISO_MIN_BYTES"; then
    return 0
  fi
  url="${VIRTIO_ISO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}"
  icache_log "virtio prefetch from upstream ${url}"
  mkdir -p "$CACHE_DIR"
  tmp="${VIRTIO_ISO}.partial.$$"
  if ! wget -q -O "$tmp" "$url"; then
    rm -f "$tmp"
    icache_log "ERROR virtio wget failed"
    return 1
  fi
  if ! local_file_ok "$tmp" "$VIRTIO_ISO_MIN_BYTES"; then
    rm -f "$tmp"
    icache_log "ERROR virtio download too small"
    return 1
  fi
  mv -f "$tmp" "$VIRTIO_ISO"
  chmod 644 "$VIRTIO_ISO" 2>/dev/null || true
  icache_log "virtio ready size=$(stat -c%s "$VIRTIO_ISO")"
  if [[ -n "$bucket" && -n "$region" ]]; then
    aws s3 cp "$VIRTIO_ISO" "s3://${bucket}/nested-virt/virtio-win.iso" --region "$region" 2>/dev/null && \
      icache_log "virtio uploaded to s3://${bucket}/nested-virt/virtio-win.iso" || true
  fi
}

# Background-friendly: both ISOs in parallel during bootstrap.
prefetch_lab_images() {
  mkdir -p "$CACHE_DIR"
  ensure_windows_iso &
  local p1=$!
  ensure_virtio_iso &
  local p2=$!
  wait "$p1" "$p2"
  icache_log "prefetch complete"
}

ensure_lab_images() {
  ensure_windows_iso
  ensure_virtio_iso
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-ensure}" in
    prefetch) prefetch_lab_images ;;
    ensure) ensure_lab_images ;;
    *) echo "usage: $0 [prefetch|ensure]"; exit 1 ;;
  esac
fi