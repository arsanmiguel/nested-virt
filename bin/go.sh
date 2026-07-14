#!/usr/bin/env bash
# Nested-virt — single entry point for deploy, guests, L2, and proofs.
#
#   ./bin/go.sh              Idempotent resume → ALL GREEN
#   ./bin/go.sh --fresh      Teardown all stacks, full deploy → ALL GREEN
#   ./bin/go.sh --teardown   Delete all nested-virt stacks
#
# Prerequisites: config.env, config.local.env (KEY_NAME), AWS creds for account in config.env
#
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"
source "${ROOT}/config.env"
[[ -f "${ROOT}/config.local.env" ]] && source "${ROOT}/config.local.env"
# shellcheck source=wait-deps.sh
source "${BIN}/wait-deps.sh"

LOG="${NESTED_VIRT_LOG:-/tmp/nested-virt-go.log}"
S3_PREFIX="s3://${BOOTSTRAP_BUCKET:-nested-virt-bootstrap-${AWS_ACCOUNT_ID}}/nested-virt"
MODE=run
for arg in "$@"; do
  case "$arg" in
    --fresh) MODE=fresh ;;
    --teardown) MODE=teardown ;;
  esac
done

step() {
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  $*"
  echo "════════════════════════════════════════════════════════════"
}

# ── Teardown ────────────────────────────────────────────────────────────────

unlock_stack_termination() {
  local name="$1" iids iid
  iids=$(aws cloudformation describe-stack-resources --stack-name "$name" --region "$AWS_REGION" \
    --query 'StackResources[?ResourceType==`AWS::EC2::Instance`].PhysicalResourceId' --output text 2>/dev/null || true)
  for iid in $iids; do
    if [[ -z "$iid" || "$iid" == "None" ]]; then continue; fi
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
  if [[ "$st" == "DELETE_COMPLETE" ]]; then return 0; fi
  echo "Deleting stack ${name} (${st})..."
  unlock_stack_termination "$name"
  aws cloudformation delete-stack --stack-name "$name" --region "$AWS_REGION"
  aws cloudformation wait stack-delete-complete --stack-name "$name" --region "$AWS_REGION" || {
    unlock_stack_termination "$name"
    aws cloudformation delete-stack --stack-name "$name" --region "$AWS_REGION" 2>/dev/null || true
    aws cloudformation wait stack-delete-complete --stack-name "$name" --region "$AWS_REGION" || true
  }
}

teardown_all() {
  step "TEARDOWN"
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
    n, st = s.get('StackName',''), s.get('StackStatus','')
    if n.startswith(base + '-') and st != 'DELETE_COMPLETE':
        print(n)
" "$base")
    while IFS= read -r s; do
      if [[ -n "$s" ]]; then delete_stack "$s"; fi
    done <<< "$stacks"
  done
  echo "# Cleared $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${ROOT}/sites.env"
  rm -f "${ROOT}"/.last-stack-site*.env 2>/dev/null || true
  "${BIN}/clean-lab-ssm.sh" 2>/dev/null || true
  "${BIN}/sweep-lab-orphans.sh" 2>/dev/null || true
  echo "Teardown complete."
}

# ── Lab security (dnsmasq port=0, VNC localhost) ─────────────────────────────

verify_lab_security_site() {
  local sid="$1" iid cmd_id out fail=0
  iid="$(site_instance_from_sites "$sid")"
  wait_ssm_online "$iid"
  cmd_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$iid" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"aws s3 cp ${S3_PREFIX}/ensure-lab-dnsmasq.sh /tmp/ensure-lab-dnsmasq.sh && aws s3 cp ${S3_PREFIX}/ensure-lab-vnc.sh /tmp/ensure-lab-vnc.sh && chmod +x /tmp/ensure-lab-dnsmasq.sh /tmp/ensure-lab-vnc.sh && bash -c 'set +e; source /tmp/ensure-lab-dnsmasq.sh; harden_metal_dns; verify_no_public_dns; d=\$?; source /tmp/ensure-lab-vnc.sh; harden_metal_vnc; verify_no_public_vnc; v=\$?; exit \$((d||v))'\"]" \
    --query Command.CommandId --output text)
  sleep 25
  out=$(aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$iid" \
    --query '[StandardOutputContent,StandardErrorContent]' --output text 2>/dev/null || true)
  echo "$out"
  echo "$out" | grep -q '^OK: no public DNS listeners' || fail=1
  echo "$out" | grep -q '^OK: no public VNC listeners' || fail=1
  [[ "$fail" -eq 0 ]] || { echo "Site ${sid} lab security check FAILED" >&2; return 1; }
  echo "Site ${sid} lab security OK"
}

verify_lab_security_both() {
  wait_sites_env
  verify_lab_security_site 0
  verify_lab_security_site 1
}

# ── Internet proof (metal + L1 Windows + L2 inner curl) ───────────────────────

inner_internet_ok_site() {
  local sid="$1" iid inner ip_ok pass_file
  iid="$(site_instance_from_sites "$sid")"
  inner="10.${sid}.1.20"
  pass_file="${NESTED_VIRT_STATE_DIR:-/var/lib/nested-virt}/inner-ubuntu-ssh-password"
  key_file="${NESTED_VIRT_STATE_DIR:-/var/lib/nested-virt}/inner-ubuntu-ssh-key"
  ip_ok=$(ssm_run "$iid" x \
    "export DEBIAN_FRONTEND=noninteractive; apt-get install -y sshpass openssh-client curl >/dev/null 2>&1; if test -f ${key_file}; then ssh -i ${key_file} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o ConnectTimeout=12 ubuntu@${inner} 'curl -sf --connect-timeout 12 https://checkip.amazonaws.com && echo INNER_OK' 2>/dev/null || true; elif test -f ${pass_file}; then PASS=\$(tr -d '[:space:]' < ${pass_file}); sshpass -p \"\$PASS\" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=12 ubuntu@${inner} 'curl -sf --connect-timeout 12 https://checkip.amazonaws.com && echo INNER_OK' 2>/dev/null || true; fi")
  echo "$ip_ok" | grep -q INNER_OK
}

ensure_internet_both() {
  step "INNER INTERNET ensure (metal + L1 + L2 curl)"
  "${BIN}/ensure-lab-internet.sh"
}

# ── Pipeline ────────────────────────────────────────────────────────────────

run_pipeline() {
  step "UPLOAD lab scripts to S3"
  "${BIN}/upload-lab-scripts.sh"

  if ! stack_deployed; then
    step "DEPLOY both sites (CFN)"
    SITE_ID=0 AVAILABILITY_ZONE="${AVAILABILITY_ZONE_A:-us-east-1a}" "${BIN}/run-site.sh"
    SITE_ID=1 AVAILABILITY_ZONE="${AVAILABILITY_ZONE_B:-us-east-1b}" "${BIN}/run-site.sh"
  else
    step "DEPLOY skipped (stacks exist)"
    ensure_both_running
  fi

  if ! bootstrap_done_both; then
    step "BOOTSTRAP wait"
    wait_bootstrap_both
  else
    step "BOOTSTRAP skipped"
    ensure_both_running
    wait_ssm_online_both
  fi

  if ! sites_env_ready; then
    step "PEER ROUTING"
    "${BIN}/configure-peer-routing.sh"
  else
    step "PEER ROUTING skipped"
  fi
  wait_sites_env

  step "Lab security verify"
  verify_lab_security_both

  step "PROOFS L0 + L1-local"
  "${BIN}/invoke-routing-proof.sh" --layer l0
  "${BIN}/invoke-routing-proof.sh" --layer l1-local

  if ! guest_up_both; then
    step "WINDOWS GUESTS"
    "${BIN}/deploy-hyperv-guest.sh"
    wait_guest_both
  else
    step "WINDOWS GUESTS skipped"
  fi

  step "GUEST FIREWALL + L1 cross/guest"
  "${BIN}/open-guest-firewall.sh"
  "${BIN}/invoke-routing-proof.sh" --layer l1-cross
  "${BIN}/invoke-routing-proof.sh" --layer l1-guest

  if ! l2_up_both; then
    step "L2 deploy (~5–15 min first site if VHDX not cached on Windows guest)"
    "${BIN}/deploy-inner-ubuntu.sh"
    wait_l2_both
  else
    step "L2 skipped (both 10.x.1.20 up)"
  fi

  step "INNER INTERNET ensure"
  ensure_internet_both

  step "FINAL PROOFS"
  "${BIN}/invoke-routing-proof.sh" --layer l2
  "${BIN}/ensure-lab-internet.sh"
  "${BIN}/invoke-routing-proof.sh" --layer internet
  "${BIN}/invoke-routing-proof.sh" --layer all

  step "ALL GREEN ✓"
  echo "Log: ${LOG}"
}

case "$MODE" in
  teardown) teardown_all | tee -a "$LOG" ;;
  fresh) teardown_all | tee -a "$LOG"; run_pipeline | tee -a "$LOG" ;;
  run) run_pipeline | tee -a "$LOG" ;;
esac
