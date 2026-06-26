#!/usr/bin/env bash
# Run containerized security scans against nested-virt (source template only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${SECURITY_SCAN_OUT:-/tmp/nested-virt-security-scan}"
TEMPLATE="${ROOT}/cloudformation/template-src.yaml"
DOCKER_HOST="${DOCKER_HOST:-unix://${HOME}/.colima/default/docker.sock}"
export DOCKER_HOST
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
mkdir -p "$OUT" "$DOCKER_CONFIG"
[[ -f "${DOCKER_CONFIG}/config.json" ]] || printf '%s\n' '{"auths":{}}' > "${DOCKER_CONFIG}/config.json"

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker unavailable (start Colima: colima start)" >&2
  exit 1
fi

echo "=== Trivy (CloudFormation source) ===" | tee "$OUT/latest-trivy.txt"
docker run --rm \
  -v "${ROOT}:/repo:ro" \
  -w /repo \
  aquasec/trivy:0.71.2 fs \
  --scanners secret,misconfig \
  --ignorefile .trivyignore \
  --format table \
  --severity HIGH,CRITICAL,MEDIUM,LOW \
  cloudformation/template-src.yaml 2>&1 | tee -a "$OUT/latest-trivy.txt"

echo "=== Checkov (CloudFormation) ===" | tee "$OUT/latest-checkov.txt"
docker run --rm -v "${ROOT}:/repo:ro" -w /repo bridgecrew/checkov:3.2.451 \
  -f cloudformation/template-src.yaml \
  --framework cloudformation --compact 2>&1 | tee -a "$OUT/latest-checkov.txt"

echo "=== Gitleaks (git history) ===" | tee "$OUT/latest-gitleaks.txt"
docker run --rm -v "${ROOT}:/repo:ro" -w /repo zricethezav/gitleaks:v8.30.1 \
  detect --redact --source /repo 2>&1 | tee -a "$OUT/latest-gitleaks.txt"

echo "Reports in ${OUT}"
