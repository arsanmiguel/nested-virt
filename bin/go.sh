#!/usr/bin/env bash
# Nested-virt workshop pipeline — single entry point.
#
#   ./bin/go.sh              Idempotent: deploy if missing, skip finished phases, run to green.
#   ./bin/go.sh --fresh      Teardown everything, then full deploy → green.
#   ./bin/go.sh --teardown   Delete all nested-virt stacks (unlock Epoxy termination first).
#
# Host-side scripts (bootstrap, dnsmasq, vnc, guest provision) live under scripts/ and are
# uploaded to S3 by deploy-stack.sh — not duplicated here. CFN owns network + EIP + IAM.
#
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"
source "${ROOT}/config.env"
[[ -f "${ROOT}/config.local.env" ]] && source "${ROOT}/config.local.env"
# shellcheck source=wait-deps.sh
source "${BIN}/wait-deps.sh"

LOG="${NESTED_VIRT_LOG:-/tmp/nested-virt-go.log}"
MODE=run
for arg in "$@"; do
  case "$arg" in
    --fresh) MODE=fresh ;;
    --teardown) MODE=teardown ;;
  esac
done

S3_PREFIX="s3://${BOOTSTRAP_BUCKET:-nested-virt-bootstrap-${AWS_ACCOUNT_ID}}/nested-virt"

step() {
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  $*"
  echo "════════════════════════════════════════════════════════════"
}

unlock_stack_termination() {
  local name="$1" iids iid
  iids=$(aws cloudformation describe-stack-resources --stack-name "$name" --region "$AWS_REGION" \
    --query 'StackResources[?ResourceType==`AWS::EC2::Instance`].PhysicalResourceId' --output text 2>/dev/null || true)
  for iid in $iids; do
    [[ -z "$iid" || "$iid" == "None" ]] && continue
    echo "  unlock termination ${iid}"
    aws ec2 modify-instance-attribute --region "$AWS_REGION" --instance-id "$iid" \
      --no-disable-api-termination 2>/dev/null || true
  done
}

delete_stack() {
  local name="$1" st
  if ! aws cloudformation describe-stacks --stack-name "$name" --region "$AWS_REGION" >/dev/null 2>&1; then
    return 0
  fi
  st=$(aws cloudformation describe-stacks --stack-name "$name" --region "$AWS_REGION" \
    --query 'Stacks[0].StackStatus' --output text)
  [[ "$st" == "DELETE_COMPLETE" ]] && return 0
  echo "Deleting stack ${name} (status=${st})..."
  unlock_stack_termination "$name"
  aws cloudformation delete-stack --stack-name "$name" --region "$AWS_REGION"
  if ! aws cloudformation wait stack-delete-complete --stack-name "$name" --region "$AWS_REGION"; then
    echo "WARN: retry delete ${name}..."
    unlock_stack_termination "$name"
    aws cloudformation delete-stack --stack-name "$name" --region "$AWS_REGION" 2>/dev/null || true
    aws cloudformation wait stack-delete-complete --stack-name "$name" --region "$AWS_REGION" || \
      echo "ERROR: stack ${name} still not deleted — check console"
  fi
}

teardown_all() {
  step "TEARDOWN all nested-virt stacks"
  local f s stacks
  for f in "${ROOT}"/.last-stack-site*.env; do
    [[ -f "$f" ]] || continue
    # shellcheck source=/dev/null
    source "$f"
    delete_stack "${STACK_NAME}"
  done
  for base in nested-virt-s0 nested-virt-s1; do
    stacks=$(aws cloudformation list-stacks --region "$AWS_REGION" --output json | python3 -c "
import json, sys
base = sys.argv[1]
for s in json.load(sys.stdin).get('StackSummaries', []):
    n = s.get('StackName', '')
    st = s.get('StackStatus', '')
    if n.startswith(base + '-') and st != 'DELETE_COMPLETE':
        print(n)
" "$base")
    while IFS= read -r s; do
      [[ -n "$s" ]] && delete_stack "$s"
    done <<< "$stacks"
  done
  cat > "${ROOT}/sites.env" <<EOF
# Cleared by go.sh --teardown $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  rm -f "${ROOT}"/.last-stack-site*.env 2>/dev/null || true
  echo "Teardown complete."
}

# CSE hardening: DNS (no public :53) + VNC (127.0.0.1 only). Scripts run on metal via SSM.
verify_cse_hardening_site() {
  local sid="$1" iid cmd_id out fail=0
  iid="$(site_instance_from_sites "$sid")"
  echo "--- Site ${sid} (${iid}) ---"
  wait_ssm_online "$iid"
  cmd_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$iid" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"aws s3 cp ${S3_PREFIX}/ensure-lab-dnsmasq.sh /tmp/ensure-lab-dnsmasq.sh && aws s3 cp ${S3_PREFIX}/ensure-lab-vnc.sh /tmp/ensure-lab-vnc.sh && chmod +x /tmp/ensure-lab-dnsmasq.sh /tmp/ensure-lab-vnc.sh && bash -c 'set +e; source /tmp/ensure-lab-dnsmasq.sh; harden_metal_dns; verify_no_public_dns; dns_rc=\$?; source /tmp/ensure-lab-vnc.sh; harden_metal_vnc; verify_no_public_vnc; vnc_rc=\$?; exit \$(( dns_rc || vnc_rc ))'\"]" \
    --query Command.CommandId --output text)
  sleep 25
  out=$(aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$iid" \
    --query '[StandardOutputContent,StandardErrorContent]' --output text 2>/dev/null || true)
  echo "$out"
  echo "$out" | grep -q '^OK: no public DNS listeners' || fail=1
  echo "$out" | grep -q '^OK: no public VNC listeners' || fail=1
  if [[ "$fail" -eq 0 ]]; then
    echo "Site ${sid} CSE hardening passed"
  else
    echo "Site ${sid} CSE hardening FAILED" >&2
    return 1
  fi
}

verify_cse_hardening_both() {
  local rc=0
  wait_sites_env
  verify_cse_hardening_site 0 || rc=1
  verify_cse_hardening_site 1 || rc=1
  [[ "$rc" -eq 0 ]] || exit 1
  echo "CSE hardening verified on both sites"
}

run_pipeline() {
  if ! stack_deployed; then
    step "DEPLOY both sites"
    SITE_ID=0 AVAILABILITY_ZONE="${AVAILABILITY_ZONE_A:-us-east-1a}" "${BIN}/run-site.sh"
    SITE_ID=1 AVAILABILITY_ZONE="${AVAILABILITY_ZONE_B:-us-east-1b}" "${BIN}/run-site.sh"
  else
    step "DEPLOY skipped (stacks exist)"
    ensure_both_running
  fi

  if ! bootstrap_done_both; then
    step "BOOTSTRAP wait (deps: ec2 running + ssm online)"
    wait_bootstrap_both
  else
    step "BOOTSTRAP skipped (both complete)"
    ensure_both_running
    wait_ssm_online_both
  fi

  if ! sites_env_ready; then
    step "PEER ROUTING (deps: bootstrap both)"
    "${BIN}/configure-peer-routing.sh"
  else
    step "PEER ROUTING skipped (sites.env ready)"
  fi
  wait_sites_env

  step "CSE hardening (DNS :53 + VNC 5900)"
  verify_cse_hardening_both

  step "PROOFS L0 + L1-local (deps: peer routing)"
  "${BIN}/invoke-routing-proof.sh" --layer l0
  "${BIN}/invoke-routing-proof.sh" --layer l1-local

  if ! guest_up_both; then
    step "WINDOWS GUESTS deploy + wait (deps: sites.env + ssm)"
    "${BIN}/deploy-hyperv-guest.sh"
    wait_guest_both
  else
    step "WINDOWS GUESTS skipped (both 10.x.1.10 up)"
  fi

  step "GUEST FIREWALL + L1 cross/guest proofs"
  "${BIN}/open-guest-firewall.sh"
  "${BIN}/invoke-routing-proof.sh" --layer l1-cross
  "${BIN}/invoke-routing-proof.sh" --layer l1-guest

  if ! l2_up_both; then
    step "L2 deploy + wait (deps: L1 guests; VHDX ~45–90 min — do not stop hosts)"
    "${BIN}/deploy-inner-ubuntu.sh"
    wait_l2_both
  else
    step "L2 skipped (both 10.x.1.20 up)"
  fi

  step "FINAL PROOFS L2 + internet + all"
  "${BIN}/invoke-routing-proof.sh" --layer l2
  "${BIN}/ensure-lab-internet.sh"
  "${BIN}/invoke-routing-proof.sh" --layer internet
  "${BIN}/invoke-routing-proof.sh" --layer all

  step "ALL GREEN ✓"
  echo "Log: ${LOG}"
}

case "$MODE" in
  teardown) teardown_all ;;
  fresh) teardown_all; run_pipeline ;;
  run) run_pipeline ;;
esac
