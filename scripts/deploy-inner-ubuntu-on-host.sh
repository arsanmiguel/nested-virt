#!/usr/bin/env bash
# Deploy Ubuntu inner Hyper-V VM on this metal host (prepare image + WinRM to Windows guest).
set -euo pipefail

TIMING_LOG=/var/log/amazon/launch-timing.log
STATE_DIR="${STATE_DIR:-/var/lib/nested-virt}"
PASS_FILE="${PASS_FILE:-${STATE_DIR}/win-guest-admin-password}"
INNER_PASS_FILE="${INNER_PASS_FILE:-${STATE_DIR}/inner-ubuntu-ssh-password}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "$(date -Iseconds) DEPLOY_INNER $*" | tee -a "$TIMING_LOG"; }

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

SITE_ID="${SITE_ID:-$(imds_tag SiteId || echo 0)}"
GUEST_IP="10.${SITE_ID}.1.10"
METAL_GW="10.${SITE_ID}.1.1"
INNER_IP="10.${SITE_ID}.1.20"
VM_MAC="$(printf '52540020%02x20' "$((10#${SITE_ID}))")"
SERVE_DIR="${STATE_DIR}/inner-ubuntu-serve"
PS1_SRC="${PS1_SRC:-${SCRIPT_DIR}/provision-ubuntu-inner-vm.ps1}"
[[ -f "$PS1_SRC" ]] || PS1_SRC="/tmp/provision-ubuntu-inner-vm.ps1"
export PS1_SRC
HTTP_PORT="${INNER_HTTP_PORT:-8090}"
FORCE="${FORCE_REINSTALL:-0}"
FORCE_VHDX_PULL="${FORCE_VHDX_PULL:-$FORCE}"

[[ -f "$PASS_FILE" ]] || { log "missing ${PASS_FILE}"; exit 1; }

LOCK_FILE="${STATE_DIR}/inner-deploy.lock"
if [[ -f "$LOCK_FILE" ]]; then
  holder="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
    log "ERROR another inner deploy is running (pid=${holder})"
    exit 1
  fi
  log "WARN removing stale inner-deploy lock (pid=${holder:-unknown})"
  rm -f "$LOCK_FILE"
fi
exec 9>"${LOCK_FILE}"
echo "$$" >&9
if ! flock -n 9; then
  log "ERROR another inner deploy holds lock ${LOCK_FILE}"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get install -y python3-pip curl qemu-utils genisoimage >/dev/null 2>&1 || true
pip3 install -q pywinrm 2>/dev/null || pip3 install --break-system-packages -q pywinrm 2>/dev/null || true

"${SCRIPT_DIR}/prepare-ubuntu-inner-image.sh" "$SITE_ID"
INNER_KEY="${STATE_DIR}/inner-ubuntu-ssh-key"
[[ -f "$INNER_PASS_FILE" ]] || { log "ERROR missing ${INNER_PASS_FILE} after prepare"; exit 1; }
[[ -f "$INNER_KEY" ]] || { log "ERROR missing ${INNER_KEY} after prepare"; exit 1; }
cp "$PS1_SRC" "${SERVE_DIR}/provision-ubuntu-inner-vm.ps1"
log "staged ps1 ${SERVE_DIR}/provision-ubuntu-inner-vm.ps1"

EXPECTED_VHDX_BYTES=$(stat -c%s "${SERVE_DIR}/ubuntu-inner.vhdx")
VHDX_SHA256=$(cat "${SERVE_DIR}/ubuntu-inner.vhdx.sha256" 2>/dev/null || sha256sum "${SERVE_DIR}/ubuntu-inner.vhdx" | awk '{print $1}')
echo "$VHDX_SHA256" > "${SERVE_DIR}/ubuntu-inner.vhdx.sha256"

pkill -f "python3 -m http.server ${HTTP_PORT} --bind ${METAL_GW}" 2>/dev/null || true
nohup python3 -m http.server "$HTTP_PORT" --bind "$METAL_GW" --directory "$SERVE_DIR" \
  >> /var/log/nested-virt-inner-http.log 2>&1 &
HTTP_PID=$!
sleep 1
if ! curl -sfI --connect-timeout 3 "http://${METAL_GW}:${HTTP_PORT}/ubuntu-inner.vhdx" >/dev/null; then
  log "ERROR HTTP serve failed on ${METAL_GW}:${HTTP_PORT}"
  kill "$HTTP_PID" 2>/dev/null || true
  exit 1
fi
log "HTTP serve ok ${METAL_GW}:${HTTP_PORT} vhdx_bytes=${EXPECTED_VHDX_BYTES}"

VHDX_URL="http://${METAL_GW}:${HTTP_PORT}/ubuntu-inner.vhdx"
SEED_URL="http://${METAL_GW}:${HTTP_PORT}/ubuntu-inner-seed.iso"
PS1_URL="http://${METAL_GW}:${HTTP_PORT}/provision-ubuntu-inner-vm.ps1"

cleanup() { kill "$HTTP_PID" 2>/dev/null || true; }
trap cleanup EXIT

export GUEST_IP PASS_FILE EXPECTED_VHDX_BYTES VHDX_URL PS1_URL SITE_ID METAL_GW SEED_URL INNER_IP VM_MAC FORCE FORCE_VHDX_PULL VHDX_SHA256

python3 <<'PY'
import os, sys, time
import winrm

guest = os.environ["GUEST_IP"]
password = open(os.environ["PASS_FILE"]).read().strip()
expected = int(os.environ["EXPECTED_VHDX_BYTES"])
vhdx_url = os.environ["VHDX_URL"]
ps1_url = os.environ["PS1_URL"]
site_id = os.environ["SITE_ID"]
metal_gw = os.environ["METAL_GW"]
seed_url = os.environ["SEED_URL"]
inner_ip = os.environ["INNER_IP"]
vm_mac = os.environ["VM_MAC"]
force = os.environ.get("FORCE", "0") == "1"
force_pull = os.environ.get("FORCE_VHDX_PULL", "0") == "1"
force_flag = "-ForceReinstall" if force else ""
vhdx_stamp = os.environ.get("VHDX_SHA256", "")


def session(read_to=180, op_to=150):
    return winrm.Session(
        f"http://{guest}:5985/wsman",
        auth=("Administrator", password),
        transport="ntlm",
        server_cert_validation="ignore",
        read_timeout_sec=read_to,
        operation_timeout_sec=op_to,
    )


def run_ps(ps, read_to=180, op_to=150):
    r = session(read_to, op_to).run_ps(ps)
    out = r.std_out.decode(errors="replace")
    err = r.std_err.decode(errors="replace")
    sys.stdout.write(out)
    sys.stderr.write(err)
    if r.status_code:
        sys.exit(r.status_code)
    return out


print(f"winrm stage ps1 guest={guest}", flush=True)
run_ps(f"""
$StateDir = 'C:\\ProgramData\\nested-virt'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
& curl.exe -f -L -o (Join-Path $StateDir 'provision-inner.ps1') '{ps1_url}'
if ($LASTEXITCODE -ne 0) {{ throw 'failed to fetch provision-inner.ps1' }}
Write-Output 'PHASE=PS1_STAGED'
""")

print(f"winrm stop inner vm before vhdx sync guest={guest}", flush=True)
run_ps(f"""
$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction SilentlyContinue
$VmName = 'ubuntu-inner'
if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {{
  Write-Output 'PHASE=VM_STOP remove inner vm before vhdx replace'
  Stop-VM -Name $VmName -Force -TurnOff -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3
  Remove-VM -Name $VmName -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
}}
""")

print(f"winrm start background vhdx download guest={guest} force_pull={force_pull}", flush=True)
run_ps(f"""
$ErrorActionPreference = 'Stop'
$StateDir = 'C:\\ProgramData\\nested-virt'
$vhdx = Join-Path $StateDir 'ubuntu-inner-disk.vhdx'
$part = "$vhdx.part"
$pidFile = Join-Path $StateDir 'vhdx-curl.pid'
$stampFile = Join-Path $StateDir 'ubuntu-inner-disk.vhdx.sha256'
$expected = {expected}
$expectedStamp = '{vhdx_stamp}'
$forcePull = ${{'true' if force_pull else 'false'}}
$stampOk = $false
if ((Test-Path $stampFile) -and ((Get-Content $stampFile -Raw).Trim() -eq $expectedStamp)) {{ $stampOk = $true }}
if ($forcePull -eq 'true' -or ((Test-Path $vhdx) -and -not $stampOk)) {{
  Write-Output "PHASE=VHDX_INVALIDATE force_pull=$forcePull stamp_ok=$stampOk"
  Get-Process -Name curl -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item $vhdx, $part, $pidFile, $stampFile -Force -ErrorAction SilentlyContinue
}}
if ((Test-Path $vhdx) -and $stampOk) {{
  Write-Output "PHASE=VHDX_READY stamp=$expectedStamp size=$((Get-Item $vhdx).Length)"
  exit 0
}}
if (Test-Path $pidFile) {{
  $old = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($old -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) {{
    Write-Output 'PHASE=VHDX_DOWNLOAD already_running'
    exit 0
  }}
}}
if (Test-Path $part) {{ Remove-Item $part -Force -ErrorAction SilentlyContinue }}
$stdout = Join-Path $StateDir 'vhdx-curl.stdout'
$stderr = Join-Path $StateDir 'vhdx-curl.stderr'
$p = Start-Process -FilePath curl.exe -ArgumentList @('-f','-L','-o', $part, '{vhdx_url}') -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$p.Id | Set-Content $pidFile
Write-Output "PHASE=VHDX_DOWNLOAD started pid=$($p.Id)"
""")

print("poll vhdx download (short WinRM probes)", flush=True)
for attempt in range(1, 121):
    out = run_ps(f"""
$StateDir = 'C:\\ProgramData\\nested-virt'
$vhdx = Join-Path $StateDir 'ubuntu-inner-disk.vhdx'
$part = "$vhdx.part"
$pidFile = Join-Path $StateDir 'vhdx-curl.pid'
$stampFile = Join-Path $StateDir 'ubuntu-inner-disk.vhdx.sha256'
$expected = {expected}
$expectedStamp = '{vhdx_stamp}'
$running = $false
if (Test-Path $pidFile) {{
  $curlPid = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($curlPid) {{ $running = $null -ne (Get-Process -Id $curlPid -ErrorAction SilentlyContinue) }}
}}
$size = 0
if (Test-Path $vhdx) {{ $size = (Get-Item $vhdx).Length }}
elseif (Test-Path $part) {{ $size = (Get-Item $part).Length }}
Write-Output "PHASE=VHDX_POLL running=$running size=$size expected=$expected"
if ((Test-Path $vhdx) -and (Test-Path $stampFile) -and ((Get-Content $stampFile -Raw).Trim() -eq $expectedStamp)) {{
  Write-Output 'PHASE=VHDX_READY'
  exit 0
}}
if (-not $running -and (Test-Path $part) -and $size -ge $expected * 0.95) {{
  Copy-Item $part $vhdx -Force
  Remove-Item $part -Force
  Set-Content -Path $stampFile -Value $expectedStamp -NoNewline
  Write-Output 'PHASE=VHDX_READY'
  exit 0
}}
if (-not $running -and $size -gt 0 -and $size -lt $expected * 0.95) {{
  Get-Content (Join-Path $StateDir 'vhdx-curl.stderr') -Tail 5 -ErrorAction SilentlyContinue
  throw "VHDX download failed size=$size expected=$expected"
}}
""", read_to=60, op_to=50)
    if "PHASE=VHDX_READY" in out:
        break
    if attempt % 6 == 0:
        print(f"  vhdx download attempt={attempt}/120", flush=True)
    time.sleep(5)
else:
    print("ERROR vhdx download timeout", flush=True)
    sys.exit(1)

run_ps(f"""
$stampFile = Join-Path 'C:\\ProgramData\\nested-virt' 'ubuntu-inner-disk.vhdx.sha256'
Set-Content -Path $stampFile -Value '{vhdx_stamp}' -NoNewline
Write-Output "PHASE=VHDX_STAMPED stamp={vhdx_stamp}"
""")

print(f"winrm provision vm (SkipDownload) guest={guest} inner={inner_ip}", flush=True)
run_ps(f"""
$ErrorActionPreference = 'Stop'
& (Join-Path 'C:\\ProgramData\\nested-virt' 'provision-inner.ps1') `
  -SiteId {site_id} -MetalGateway '{metal_gw}' -VhdxUrl '{vhdx_url}' -SeedUrl '{seed_url}' `
  -InnerIp '{inner_ip}' -VmMac '{vm_mac}' -SkipDownload -SkipSeed {force_flag}
""", read_to=900, op_to=800)
PY

log "wait for inner SSH ${INNER_IP}"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y sshpass openssh-client >/dev/null 2>&1 || true
INNER_KEY="${STATE_DIR}/inner-ubuntu-ssh-key"
SSH_OK=0
for _ in $(seq 1 60); do
  if ping -c1 -W2 "$INNER_IP" >/dev/null 2>&1; then
    if [[ -f "$INNER_KEY" ]]; then
      if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i "$INNER_KEY" -o PreferredAuthentications=publickey -o PasswordAuthentication=no \
        -o ConnectTimeout=8 "ubuntu@${INNER_IP}" 'echo INNER_SSH_OK' 2>/dev/null | grep -q INNER_SSH_OK; then
        SSH_OK=1
        break
      fi
    else
      INNER_PASS=$(tr -d '[:space:]' < "$INNER_PASS_FILE")
      if sshpass -p "$INNER_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8 \
        "ubuntu@${INNER_IP}" 'echo INNER_SSH_OK' 2>/dev/null | grep -q INNER_SSH_OK; then
        SSH_OK=1
        break
      fi
    fi
  fi
  sleep 10
done
if [[ "$SSH_OK" -eq 1 ]]; then
  log "PHASE=INNER_UBUNTU_OK ip=${INNER_IP}"
  if [[ "${SKIP_INNER_DNS_ENSURE:-0}" != "1" && -x "${SCRIPT_DIR}/ensure-inner-guest-dns.sh" ]]; then
    REFRESH_INNER_VHDX=0 "${SCRIPT_DIR}/ensure-inner-guest-dns.sh" "$SITE_ID" || log "WARN inner internet patch incomplete"
  fi
  exit 0
fi
log "PHASE=INNER_UBUNTU_FAIL ip=${INNER_IP} timeout (ping or ssh)"
exit 1
