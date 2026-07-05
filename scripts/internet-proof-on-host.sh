#!/usr/bin/env bash
# Internet proof on one metal host: metal outbound, L1 Windows HTTPS, L2 inner curl.
set -euo pipefail

SITE_ID="${1:-0}"
STATE_DIR="${STATE_DIR:-/var/lib/nested-virt}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUEST_IP="10.${SITE_ID}.1.10"
INNER_IP="10.${SITE_ID}.1.20"
INNER_PASS_FILE="${INNER_PASS_FILE:-${STATE_DIR:-/var/lib/nested-virt}/inner-ubuntu-ssh-password}"
INNER_KEY="${INNER_KEY:-${STATE_DIR:-/var/lib/nested-virt}/inner-ubuntu-ssh-key}"
PASS_FILE="${PASS_FILE:-${STATE_DIR}/win-guest-admin-password}"

fail=0
ok() { echo "PHASE=INTERNET_OK layer=$1 site=${SITE_ID}"; }
bad() { echo "PHASE=INTERNET_FAIL layer=$1 site=${SITE_ID} reason=$2"; fail=1; }

echo "=== site ${SITE_ID} metal outbound ==="
if curl -sf --connect-timeout 12 https://checkip.amazonaws.com >/dev/null; then
  ok metal
else
  bad metal curl_checkip
fi

if [[ -x "${SCRIPT_DIR}/ensure-inner-guest-dns.sh" ]]; then
  "${SCRIPT_DIR}/ensure-inner-guest-dns.sh" "$SITE_ID" || true
elif [[ -x /tmp/ensure-inner-guest-dns.sh ]]; then
  /tmp/ensure-inner-guest-dns.sh "$SITE_ID" || true
fi

if [[ -f "$PASS_FILE" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y python3-pip sshpass openssh-client curl >/dev/null 2>&1 || true
  pip3 install -q pywinrm 2>/dev/null || pip3 install --break-system-packages -q pywinrm 2>/dev/null || true
  echo "=== site ${SITE_ID} L1 Windows guest HTTPS ==="
  if python3 - "$GUEST_IP" "$PASS_FILE" <<'PY'
import sys, winrm
guest, pw = sys.argv[1:3]
password = open(pw).read().strip()
s = winrm.Session(f"http://{guest}:5985/wsman", auth=("Administrator", password),
                  transport="ntlm", server_cert_validation="ignore", read_timeout_sec=90)
r = s.run_ps("(Invoke-WebRequest -Uri https://aws.amazon.com -UseBasicParsing -TimeoutSec 20).StatusCode")
out = (r.std_out or b"").decode().strip()
print(out)
sys.exit(0 if out == "200" and r.status_code == 0 else 1)
PY
  then
    ok l1-guest
  else
    bad l1-guest https
  fi
else
  bad l1-guest no_password_file
fi

echo "=== site ${SITE_ID} L2 inner curl ==="
inner_ok=0
if [[ -f "$INNER_KEY" ]]; then
  :
elif [[ -n "${INNER_SSH_PASS:-}" ]]; then
  INNER_PASS="$INNER_SSH_PASS"
elif [[ -f "$INNER_PASS_FILE" ]]; then
  INNER_PASS=$(tr -d '[:space:]' < "$INNER_PASS_FILE")
else
  bad l2-inner no_credentials
fi
if [[ "${fail}" -eq 0 ]]; then
for _ in $(seq 1 6); do
  if [[ -f "$INNER_KEY" ]]; then
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -i "$INNER_KEY" -o PreferredAuthentications=publickey -o PasswordAuthentication=no \
      -o ConnectTimeout=12 "ubuntu@${INNER_IP}" \
      'curl -sf --connect-timeout 12 https://checkip.amazonaws.com && echo INNER_OK' 2>/dev/null | grep -q INNER_OK; then
      inner_ok=1
      break
    fi
  elif sshpass -p "${INNER_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=12 "ubuntu@${INNER_IP}" \
    'curl -sf --connect-timeout 12 https://checkip.amazonaws.com && echo INNER_OK' 2>/dev/null | grep -q INNER_OK; then
    inner_ok=1
    break
  fi
  sleep 10
done
fi
if [[ "$inner_ok" -eq 1 ]]; then
  ok l2-inner
else
  bad l2-inner curl_checkip
fi

if (( fail )); then
  echo "Internet proof FAILED site=${SITE_ID}"
  exit 1
fi
echo "Internet proof PASSED site=${SITE_ID}"
