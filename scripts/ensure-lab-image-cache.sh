#!/usr/bin/env bash
# Lab image cache on /var/lib/libvirt/images (data EBS). ISOs fetched over HTTPS or S3.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

CACHE_DIR="${LAB_IMAGE_CACHE_DIR:-/var/lib/libvirt/images}"
CACHE_MARKER="${CACHE_DIR}/.nested-virt-cache-v1"
WIN_ISO="${CACHE_DIR}/Win2022.iso"
VIRTIO_ISO="${CACHE_DIR}/virtio-win.iso"
WIN_ISO_MIN_BYTES="${WIN_ISO_MIN_BYTES:-5000000000}"
VIRTIO_ISO_MIN_BYTES="${VIRTIO_ISO_MIN_BYTES:-700000000}"
DEFAULT_WIN_ISO_URL="${DEFAULT_WIN_ISO_URL:-https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso}"

icache_log() { echo "$(date -Iseconds) IMAGE_CACHE $*"; }

imds_token() {
  curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

imds_tag() {
  local key="$1" token
  token="$(imds_token)"
  curl -sf -H "X-aws-ec2-metadata-token: ${token}" \
    "http://169.254.169.254/latest/meta-data/tags/instance/${key}" 2>/dev/null || true
}

lab_account_id() {
  curl -sf -H "X-aws-ec2-metadata-token: $(imds_token)" \
    http://169.254.169.254/latest/dynamic/instance-identity/document 2>/dev/null | \
    sed -n 's/.*"accountId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true
}

lab_region() {
  curl -sf -H "X-aws-ec2-metadata-token: $(imds_token)" \
    http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true
}

stack_bootstrap_bucket() {
  imds_tag BootstrapBucket
}

account_bootstrap_bucket() {
  local account
  account="$(lab_account_id)"
  if [[ -n "$account" ]]; then echo "nested-virt-bootstrap-${account}"; fi
}

windows_iso_download_url() {
  local url="${WINDOWS_ISO_DOWNLOAD_URL:-${WINDOWS_ISO_URL:-}}"
  if [[ -n "$url" ]]; then echo "$url"; return 0; fi
  url="$(imds_tag WindowsIsoDownloadUrl)"
  if [[ -n "$url" ]]; then echo "$url"; return 0; fi
  echo "$DEFAULT_WIN_ISO_URL"
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

ensure_http_cached() {
  local label="$1" url="$2" dest="$3" min_bytes="$4"
  local tmp
  if local_file_ok "$dest" "$min_bytes"; then
    icache_log "${label} cache hit ${dest} size=$(stat -c%s "$dest")"
    return 0
  fi
  mkdir -p "$CACHE_DIR"
  tmp="${dest}.partial.$$"
  icache_log "${label} prefetch from ${url}"
  if ! curl -fL --retry 3 --retry-delay 10 -o "$tmp" "$url"; then
    rm -f "$tmp"
    icache_log "ERROR ${label} download failed ${url}"
    return 1
  fi
  if ! local_file_ok "$tmp" "$min_bytes"; then
    rm -f "$tmp"
    icache_log "ERROR ${label} download too small"
    return 1
  fi
  mv -f "$tmp" "$dest"
  chmod 644 "$dest" 2>/dev/null || true
  icache_log "${label} ready size=$(stat -c%s "$dest")"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$CACHE_MARKER" 2>/dev/null || true
}

s3_object_size() {
  local uri="$1" region="$2" bucket key
  bucket="${uri#s3://}"; bucket="${bucket%%/*}"
  key="${uri#s3://${bucket}/}"
  aws s3api head-object --region "$region" --bucket "$bucket" --key "$key" \
    --query ContentLength --output text 2>/dev/null || echo ""
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

ensure_windows_iso_from_s3() {
  local uri="${WINDOWS_ISO_S3_URI:-}" region bucket key size
  region="$(lab_region)"
  if [[ -n "$uri" ]]; then
    ensure_s3_object_cached "windows" "$uri" "$region" "$WIN_ISO" "$WIN_ISO_MIN_BYTES"
    return $?
  fi
  for bucket in "$(stack_bootstrap_bucket)" "$(account_bootstrap_bucket)"; do
    if [[ -z "$bucket" ]]; then continue; fi
    key="nested-virt/Win2022.iso"
    size=$(aws s3api head-object --region "$region" --bucket "$bucket" --key "$key" \
      --query ContentLength --output text 2>/dev/null || true)
    if [[ -n "$size" && "$size" != "None" && "$size" -ge "$WIN_ISO_MIN_BYTES" ]]; then
      ensure_s3_object_cached "windows" "s3://${bucket}/${key}" "$region" "$WIN_ISO" "$WIN_ISO_MIN_BYTES"
      return $?
    fi
  done
  return 1
}

ensure_windows_iso() {
  local url
  url="$(windows_iso_download_url)"
  if [[ -n "$url" ]]; then
    if ensure_http_cached "windows" "$url" "$WIN_ISO" "$WIN_ISO_MIN_BYTES"; then
      return 0
    fi
    icache_log "windows https failed; trying s3 fallback"
  fi
  ensure_windows_iso_from_s3 || {
    icache_log "windows iso: no HTTPS or S3 source available"
    return 1
  }
}

ensure_virtio_iso() {
  local uri region bucket url tmp size
  region="$(lab_region)"
  for bucket in "$(stack_bootstrap_bucket)" "$(account_bootstrap_bucket)"; do
    if [[ -z "$bucket" ]]; then continue; fi
    uri="s3://${bucket}/nested-virt/virtio-win.iso"
    size=$(aws s3api head-object --region "$region" --bucket "$bucket" --key nested-virt/virtio-win.iso \
      --query ContentLength --output text 2>/dev/null || true)
    if [[ -n "$size" && "$size" != "None" ]]; then
      if ensure_s3_object_cached "virtio" "$uri" "$region" "$VIRTIO_ISO" "$VIRTIO_ISO_MIN_BYTES"; then
        return 0
      fi
    fi
  done
  url="${VIRTIO_ISO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}"
  ensure_http_cached "virtio" "$url" "$VIRTIO_ISO" "$VIRTIO_ISO_MIN_BYTES"
  bucket="$(stack_bootstrap_bucket)"
  region="$(lab_region)"
  if [[ -n "$bucket" && -n "$region" ]]; then
    aws s3 cp "$VIRTIO_ISO" "s3://${bucket}/nested-virt/virtio-win.iso" --region "$region" 2>/dev/null && \
      icache_log "virtio uploaded to s3://${bucket}/nested-virt/virtio-win.iso" || true
  fi
}

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
