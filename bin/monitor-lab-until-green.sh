#!/usr/bin/env bash
# Poll until lab verification is definitively GREEN (or RED / timeout).
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"
[[ -f "${ROOT}/config.env" ]] && source "${ROOT}/config.env"

REGION="${AWS_REGION:-us-east-1}"
STACK="${LAB_STACK_NAME:-nested-virt-lab}"
INTERVAL="${LAB_MONITOR_INTERVAL:-300}"
MAX_WAIT="${LAB_MONITOR_MAX_WAIT:-14400}"
LOG="${LAB_MONITOR_LOG:-/tmp/nested-virt-monitor.log}"
START=$(date +%s)

log() { echo "$(date -Iseconds) $*" | tee -a "$LOG"; }

log "monitor START stack=${STACK} region=${REGION} interval=${INTERVAL}s max_wait=${MAX_WAIT}s"

while true; do
  elapsed=$(( $(date +%s) - START ))
  if (( elapsed > MAX_WAIT )); then
    log "monitor TIMEOUT after ${elapsed}s"
    exit 3
  fi

  if ! aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1; then
    log "monitor AWS creds expired — refresh login and re-run, or wait for auto-refresh"
    sleep "$INTERVAL"
    continue
  fi

  set +e
  out=$("$BIN/check-lab-status.sh" 2>&1)
  rc=$?
  set -e
  log "check rc=${rc}"
  echo "$out" | tee -a "$LOG"

  if (( rc == 0 )); then
    log "monitor DONE — LAB STATUS GREEN (${elapsed}s elapsed)"
    exit 0
  fi
  if (( rc == 1 )); then
    log "monitor FAILED — LAB STATUS RED (${elapsed}s elapsed)"
    exit 1
  fi

  # rc 2 = still running
  for iid in $(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query 'Stacks[0].Outputs[?ends_with(OutputKey, `InstanceId`)].OutputValue' --output text 2>/dev/null || true); do
    if [[ -z "$iid" || "$iid" == "None" ]]; then continue; fi
    phase=$(aws ssm send-command --region "$REGION" --instance-ids "$iid" --document-name AWS-RunShellScript \
      --parameters 'commands=["echo pipeline=$(cat /var/lib/nested-virt/lab-pipeline-phase 2>/dev/null || echo none)"]' \
      --query Command.CommandId --output text 2>/dev/null || echo "")
    if [[ -z "$phase" ]]; then continue; fi
    sleep 5
    pout=$(aws ssm get-command-invocation --region "$REGION" --command-id "$phase" --instance-id "$iid" \
      --query StandardOutputContent --output text 2>/dev/null || echo "?")
    log "  ${iid}: ${pout//$'\n'/ }"
  done

  log "monitor sleeping ${INTERVAL}s..."
  sleep "$INTERVAL"
done
