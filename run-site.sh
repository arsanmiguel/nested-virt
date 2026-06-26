#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# Preserve caller env before config.env (must not export SITE_ID there)
_CALLER_SITE_ID="${SITE_ID:-}"
_CALLER_AZ="${AVAILABILITY_ZONE:-}"
if [[ ! -f "${ROOT}/config.env" ]]; then
  echo "Missing ${ROOT}/config.env — copy and edit: cp config.env.example config.env"
  exit 1
fi
source "${ROOT}/config.env"
[[ -f "${ROOT}/config.local.env" ]] && source "${ROOT}/config.local.env"

: "${KEY_NAME:?export KEY_NAME in config.local.env}"

export SITE_ID="${_CALLER_SITE_ID:-0}"
export AVAILABILITY_ZONE="${_CALLER_AZ:-us-east-1a}"
export TARGET_AVAILABILITY_ZONE="${AVAILABILITY_ZONE}"
export STACK_BASE_NAME="${STACK_BASE_NAME:-nested-virt-s${SITE_ID}}"
export LAUNCH_INSTANCE="${LAUNCH_INSTANCE:-true}"

CFN_PARAMS="${ROOT}/cloudformation/parameters.json"
if [[ ! -f "${CFN_PARAMS}" ]]; then
  cp "${ROOT}/cloudformation/parameters.example.json" "${CFN_PARAMS}"
fi

echo "=== Deploy site ${SITE_ID} in ${AVAILABILITY_ZONE} (base=${STACK_BASE_NAME}) ==="
KEY_NAME="${KEY_NAME}" SITE_ID="${SITE_ID}" LAUNCH_INSTANCE="${LAUNCH_INSTANCE}" \
  AVAILABILITY_ZONE="${AVAILABILITY_ZONE}" TARGET_AVAILABILITY_ZONE="${AVAILABILITY_ZONE}" \
  "${ROOT}/cloudformation/deploy-stack.sh"

echo "Done. Poll: SITE_ID=${SITE_ID} ./poll-timing.sh"
