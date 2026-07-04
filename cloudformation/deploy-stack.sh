#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
_CALLER_SITE_ID="${SITE_ID:-}"
_CALLER_AZ="${AVAILABILITY_ZONE:-${TARGET_AVAILABILITY_ZONE:-}}"
source "${ROOT}/config.env"
[[ -f "${ROOT}/config.local.env" ]] && source "${ROOT}/config.local.env"

LAUNCH_INSTANCE="${LAUNCH_INSTANCE:-true}"
KEY_NAME="${KEY_NAME:-}"
PARAMS_FILE="${PARAMS_FILE:-${SCRIPT_DIR}/parameters.json}"
SITE_ID="${_CALLER_SITE_ID:-0}"
export SITE_ID
export TARGET_AVAILABILITY_ZONE="${_CALLER_AZ:-us-east-1a}"
export AVAILABILITY_ZONE="${TARGET_AVAILABILITY_ZONE}"

if [[ "${AUTO_INCREMENT_STACK:-true}" == "true" ]]; then
  STACK_NAME="$("${SCRIPT_DIR}/resolve-stack-name.sh")"
  echo "AUTO_INCREMENT_STACK: using stack name ${STACK_NAME}"
else
  STACK_NAME="${STACK_NAME:?Set STACK_NAME or AUTO_INCREMENT_STACK=true}"
fi
export STACK_NAME

if [[ -z "${KEY_NAME}" ]]; then
  echo "Set KEY_NAME=your-keypair"
  exit 1
fi

BOOTSTRAP_BUCKET="nested-virt-bootstrap-${AWS_ACCOUNT_ID}"
echo "BOOTSTRAP_BUCKET=${BOOTSTRAP_BUCKET}" > "${SCRIPT_DIR}/.bootstrap-bucket.env"
export BOOTSTRAP_BUCKET

echo "=== Upload bootstrap.sh to S3 ==="
if ! aws s3api head-bucket --bucket "${BOOTSTRAP_BUCKET}" >/dev/null 2>&1; then
  if [[ "${AWS_REGION}" != "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${BOOTSTRAP_BUCKET}" --region "${AWS_REGION}" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" 2>/dev/null || true
  else
    aws s3api create-bucket --bucket "${BOOTSTRAP_BUCKET}" --region "${AWS_REGION}" || true
  fi
fi
aws s3 cp "${ROOT}/bootstrap.sh" "s3://${BOOTSTRAP_BUCKET}/nested-virt/bootstrap.sh" --region "${AWS_REGION}"
aws s3 cp "${ROOT}/scripts/ensure-lab-dnsmasq.sh" "s3://${BOOTSTRAP_BUCKET}/nested-virt/ensure-lab-dnsmasq.sh" --region "${AWS_REGION}"
aws s3 cp "${ROOT}/scripts/ensure-lab-vnc.sh" "s3://${BOOTSTRAP_BUCKET}/nested-virt/ensure-lab-vnc.sh" --region "${AWS_REGION}"
aws s3 cp "${ROOT}/scripts/ensure-lab-image-cache.sh" "s3://${BOOTSTRAP_BUCKET}/nested-virt/ensure-lab-image-cache.sh" --region "${AWS_REGION}"
aws s3 cp "${ROOT}/scripts/apply-peer-routes.sh" "s3://${BOOTSTRAP_BUCKET}/nested-virt/apply-peer-routes.sh" --region "${AWS_REGION}"
aws s3 cp "${ROOT}/scripts/fix-transport-routing.sh" "s3://${BOOTSTRAP_BUCKET}/nested-virt/fix-transport-routing.sh" --region "${AWS_REGION}"
aws s3 cp "${ROOT}/scripts/setup-gre-tunnel.sh" "s3://${BOOTSTRAP_BUCKET}/nested-virt/setup-gre-tunnel.sh" --region "${AWS_REGION}"
echo "Uploaded s3://${BOOTSTRAP_BUCKET}/nested-virt/bootstrap.sh"

python3 "${SCRIPT_DIR}/package-template.py"

if [[ ! -f "${PARAMS_FILE}" ]]; then
  cp "${SCRIPT_DIR}/parameters.example.json" "${PARAMS_FILE}"
fi

build_param_overrides() {
  local overrides_file
  overrides_file="$(mktemp)"
  LAUNCH_INSTANCE="${LAUNCH_INSTANCE}" KEY_NAME="${KEY_NAME}" STACK_NAME="${STACK_NAME}" \
    SITE_ID="${SITE_ID}" \
    METAL_SUBNET_ID="${METAL_SUBNET_ID:-}" \
    EXTRA_HOST_NIC_SUBNET_ID="${EXTRA_HOST_NIC_SUBNET_ID:-}" \
    PEER_TRANSPORT_ENI_IP="${PEER_TRANSPORT_ENI_IP:-}" \
    PEER_LAB_SUPERNET="${PEER_LAB_SUPERNET:-}" \
    python3 "${SCRIPT_DIR}/build-param-overrides.py" "${PARAMS_FILE}" "${overrides_file}"
  PARAM_OVERRIDES=()
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    [[ -n "${_line}" ]] && PARAM_OVERRIDES+=("${_line}")
  done < "${overrides_file}"
  rm -f "${overrides_file}"
}

stack_failed_on_capacity() {
  local events
  events=$(aws cloudformation describe-stack-events --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --max-items 20 --output json 2>/dev/null) || return 1
  echo "${events}" | python3 -c "
import json, sys
for e in json.loads(sys.stdin.read()).get('StackEvents', []):
    if e.get('LogicalResourceId') == 'LinuxInstance' and e.get('ResourceStatus') == 'CREATE_FAILED':
        r = (e.get('ResourceStatusReason') or '').lower()
        if 'capacity' in r or 'insufficient' in r:
            sys.exit(0)
sys.exit(1)
"
}

wait_for_rollback_if_needed() {
  local st
  st=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE)
  if [[ "$st" == "ROLLBACK_IN_PROGRESS" ]]; then
    aws cloudformation wait stack-rollback-complete --stack-name "${STACK_NAME}" --region "${AWS_REGION}"
  fi
}

delete_stack_if_present() {
  wait_for_rollback_if_needed
  if aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    aws cloudformation delete-stack --stack-name "${STACK_NAME}" --region "${AWS_REGION}"
    aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" --region "${AWS_REGION}" || true
  fi
}

deploy_stack_once() {
  local subnet="$1" az="$2"
  export METAL_SUBNET_ID="${subnet}"
  if [[ "${LAUNCH_INSTANCE}" == "true" ]]; then
    export EXTRA_HOST_NIC_SUBNET_ID="$("${SCRIPT_DIR}/ensure-kvm-nic-subnet.sh" "${az}")"
    echo "ExtraHostNicSubnetId=${EXTRA_HOST_NIC_SUBNET_ID} (${az})"
  else
    export EXTRA_HOST_NIC_SUBNET_ID=""
  fi
  build_param_overrides
  echo "Deploying ${STACK_NAME} SiteId=${SITE_ID} SubnetId=${subnet} (${az})"
  set +e
  aws cloudformation deploy \
    --stack-name "${STACK_NAME}" \
    --template-file "${SCRIPT_DIR}/packaged-template.yaml" \
    --parameter-overrides "${PARAM_OVERRIDES[@]}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset
  local rc=$?
  set -e
  local st
  st=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE)
  echo "Stack status: ${st} (exit ${rc})"
  if [[ "$st" == "CREATE_COMPLETE" || "$st" == "UPDATE_COMPLETE" ]]; then
    return 0
  fi
  wait_for_rollback_if_needed
  if stack_failed_on_capacity; then return 2; fi
  return 1
}

DEPLOY_OK=0
if [[ "${LAUNCH_INSTANCE}" == "true" && "${AUTO_FIND_METAL_SUBNET:-true}" == "true" ]]; then
  echo "=== Metal launch (AZ=${TARGET_AVAILABILITY_ZONE:-any}) ==="
  METAL_CANDIDATES_FILE="$(mktemp)"
  trap 'rm -f "${METAL_CANDIDATES_FILE}"' EXIT
  "${SCRIPT_DIR}/find-metal-subnet.sh" --list-ordered > "${METAL_CANDIDATES_FILE}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    read -r SUBNET AZ _REST <<< "$line"
    deploy_stack_once "$SUBNET" "$AZ"
    rc=$?
    if [[ "$rc" -eq 0 ]]; then DEPLOY_OK=1; break; fi
    if [[ "$rc" -eq 2 ]]; then
      delete_stack_if_present
      continue
    fi
    exit 1
  done < "${METAL_CANDIDATES_FILE}"
  [[ "$DEPLOY_OK" -eq 1 ]] || { echo "ERROR: no metal capacity"; exit 1; }
else
  export METAL_SUBNET_ID="${METAL_SUBNET_ID:-${PRIVATE_SUBNET_ID}}"
  deploy_stack_once "${METAL_SUBNET_ID}" "${TARGET_AVAILABILITY_ZONE:-configured}" || exit 1
fi

echo ""
aws cloudformation describe-stacks --stack-name "${STACK_NAME}" \
  --query 'Stacks[0].Outputs' --output table

if [[ "${LAUNCH_INSTANCE}" == "true" ]]; then
  IID=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
  TRANSPORT_IP=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='TransportNic1PrivateIp'].OutputValue" --output text)
  PUBLIC_IP=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='PublicIp'].OutputValue" --output text 2>/dev/null || echo "")
  ENV_FILE="${ROOT}/.last-stack-site${SITE_ID}.env"
  {
    echo "STACK_NAME=${STACK_NAME}"
    echo "INSTANCE_ID=${IID}"
    echo "SITE_ID=${SITE_ID}"
    echo "TRANSPORT_IP=${TRANSPORT_IP}"
    if [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "None" ]]; then
      echo "PUBLIC_IP=${PUBLIC_IP}"
    fi
    echo "AVAILABILITY_ZONE=${TARGET_AVAILABILITY_ZONE:-unknown}"
    echo "DEPLOYED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${ENV_FILE}"
  echo "Wrote ${ENV_FILE}"
fi
