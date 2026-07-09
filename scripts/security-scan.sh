#!/usr/bin/env bash
# Run containerized security scans for CSE / internal review.
# Requires Docker (Colima on macOS: colima start).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${SECURITY_SCAN_OUT:-/tmp/nested-virt-security-scan}"
DOCKER_HOST="${DOCKER_HOST:-unix://${HOME}/.colima/default/docker.sock}"
export DOCKER_HOST
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
mkdir -p "$OUT" "$DOCKER_CONFIG"
[[ -f "${DOCKER_CONFIG}/config.json" ]] || printf '%s\n' '{"auths":{}}' > "${DOCKER_CONFIG}/config.json"

TEMPLATE_SRC="${ROOT}/cloudformation/template-src.yaml"
TEMPLATE_DROPIN="${ROOT}/cloudformation/nested-virt-lab.yaml"

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker unavailable (start Colima: colima start)" >&2
  exit 1
fi

scan_cfn() {
  local label="$1"
  local rel="$2"
  local path="${ROOT}/${rel}"
  if [[ ! -f "$path" ]]; then
    echo "WARN: missing ${path} — skip ${label}" >&2
    return 0
  fi

  echo "=== Trivy (${label}) ===" | tee "$OUT/latest-trivy-${label}.txt"
  docker run --rm \
    -v "${ROOT}:/repo:ro" \
    -w /repo \
    aquasec/trivy:0.71.2 fs \
    --scanners secret,misconfig \
    --ignorefile .trivyignore \
    --format table \
    --severity HIGH,CRITICAL,MEDIUM,LOW \
    "$rel" 2>&1 | tee -a "$OUT/latest-trivy-${label}.txt" || true

  echo "=== Checkov (${label}) ===" | tee "$OUT/latest-checkov-${label}.txt"
  docker run --rm -v "${ROOT}:/repo:ro" -w /repo bridgecrew/checkov:3.2.451 \
    -f "$rel" \
    --framework cloudformation --compact 2>&1 | tee -a "$OUT/latest-checkov-${label}.txt" || true
}

scan_cfn template-src cloudformation/template-src.yaml
scan_cfn nested-virt-lab cloudformation/nested-virt-lab.yaml

echo "=== Gitleaks (git history) ===" | tee "$OUT/latest-gitleaks.txt"
docker run --rm -v "${ROOT}:/repo:ro" -w /repo zricethezav/gitleaks:v8.30.1 \
  detect --redact --source /repo 2>&1 | tee -a "$OUT/latest-gitleaks.txt" || true

if command -v cfn-lint >/dev/null 2>&1; then
  echo "=== cfn-lint ===" | tee "$OUT/latest-cfn-lint.txt"
  cfn-lint "$TEMPLATE_SRC" "$TEMPLATE_DROPIN" 2>&1 | tee -a "$OUT/latest-cfn-lint.txt" || true
else
  echo "SKIP cfn-lint (not installed; pip install cfn-lint)" | tee "$OUT/latest-cfn-lint.txt"
fi

if command -v shellcheck >/dev/null 2>&1; then
  echo "=== shellcheck ===" | tee "$OUT/latest-shellcheck.txt"
  find "${ROOT}/bin" "${ROOT}/scripts" -name '*.sh' -print0 \
    | xargs -0 shellcheck -x 2>&1 | tee -a "$OUT/latest-shellcheck.txt" || true
  shellcheck -x "${ROOT}/bootstrap.sh" 2>&1 | tee -a "$OUT/latest-shellcheck.txt" || true
else
  echo "SKIP shellcheck (not installed; brew install shellcheck)" | tee "$OUT/latest-shellcheck.txt"
fi

echo ""
echo "Reports in ${OUT}"
echo "Documented exceptions: docs/SECURITY-EXCEPTIONS.md"
echo "Trivy suppressions: .trivyignore"
