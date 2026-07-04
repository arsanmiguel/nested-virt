#!/usr/bin/env bash
# Shared dependency gates for the nested-virt pipeline.
# Sourced by bin/go.sh — do not run directly.
set -euo pipefail

: "${ROOT:?ROOT must be set}"
: "${AWS_REGION:?AWS_REGION must be set}"

# --- helpers ---

_log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [deps] $*"; }

site_stack_env() {
  local sid="${1:?site id}"
  echo "${ROOT}/.last-stack-site${sid}.env"
}

site_instance_from_stack() {
  local sid="$1" envf
  envf="$(site_stack_env "$sid")"
  [[ -f "$envf" ]] || return 1
  # shellcheck source=/dev/null
  source "$envf"
  echo "$INSTANCE_ID"
}

site_instance_from_sites() {
  local sid="$1" var
  sid="${1:?site id}"
  var="SITE_${sid}_INSTANCE_ID"
  [[ -f "${ROOT}/sites.env" ]] || return 1
  # shellcheck source=/dev/null
  source "${ROOT}/sites.env"
  echo "${!var}"
}

ec2_state() {
  aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo unknown
}

# --- EC2 / SSM gates ---

ensure_instance_running() {
  local iid="${1:?instance id}" st attempt
  for attempt in $(seq 1 40); do
    st=$(ec2_state "$iid")
    case "$st" in
      running) _log "ec2 running ${iid}"; return 0 ;;
      stopped)
        _log "starting stopped instance ${iid}"
        aws ec2 modify-instance-attribute --region "$AWS_REGION" --instance-id "$iid" \
          --no-disable-api-termination 2>/dev/null || true
        aws ec2 start-instances --region "$AWS_REGION" --instance-ids "$iid" >/dev/null
        ;;
      stopping|pending)
        _log "  ec2 ${iid} state=${st} attempt=${attempt}/40"
        ;;
      *)
        _log "ERROR ec2 ${iid} bad state=${st}"
        return 1
        ;;
    esac
    sleep 10
  done
  _log "ERROR ec2 ${iid} not running after timeout"
  return 1
}

ensure_both_running() {
  local rc=0
  ensure_instance_running "$(site_instance_from_stack 0)" || rc=1
  ensure_instance_running "$(site_instance_from_stack 1)" || rc=1
  return "$rc"
}

wait_ec2_running() { ensure_instance_running "$1"; }

wait_ssm_online() {
  local iid="${1:?instance id}" attempt status
  ensure_instance_running "$iid"
  _log "wait_ssm_online ${iid}"
  for attempt in $(seq 1 48); do
    status=$(aws ssm describe-instance-information --region "$AWS_REGION" \
      --filters "Key=InstanceIds,Values=${iid}" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)
    if [[ "$status" == "Online" ]]; then
      _log "ssm online ${iid}"
      return 0
    fi
    _log "  ssm ${iid} ping=${status} attempt=${attempt}/48"
    sleep 15
  done
  _log "ERROR ssm ${iid} not online after timeout"
  return 1
}

wait_ssm_online_site() {
  wait_ssm_online "$(site_instance_from_stack "$1")"
}

wait_ssm_online_both() {
  local p0 p1 rc=0
  wait_ssm_online_site 0 & p0=$!
  wait_ssm_online_site 1 & p1=$!
  wait "$p0" || rc=1
  wait "$p1" || rc=1
  return "$rc"
}

ssm_run() {
  local iid="${1:?instance id}" remote_cmd="${3:?command}"
  wait_ssm_online "$iid"
  local cmd_id out
  cmd_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$iid" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"${remote_cmd}\"]" \
    --query Command.CommandId --output text)
  sleep 10
  aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$iid" \
    --query StandardOutputContent --output text 2>/dev/null || true
}

# --- Phase probes (return 0 = satisfied, 1 = needs work) ---

stack_deployed() {
  [[ -f "$(site_stack_env 0)" && -f "$(site_stack_env 1)" ]]
}

bootstrap_done_site() {
  local sid="$1" iid out
  iid="$(site_instance_from_stack "$sid")" || return 1
  st=$(ec2_state "$iid")
  [[ "$st" == "running" ]] || return 1
  status=$(aws ssm describe-instance-information --region "$AWS_REGION" \
    --filters "Key=InstanceIds,Values=${iid}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)
  [[ "$status" == "Online" ]] || return 1
  out=$(ssm_run "$iid" x 'grep BOOTSTRAP.finished /var/log/amazon/launch-timing.log | tail -1 || true')
  echo "$out" | grep -q 'BOOTSTRAP finished'
}

bootstrap_done_both() {
  bootstrap_done_site 0 && bootstrap_done_site 1
}

sites_env_ready() {
  [[ -f "${ROOT}/sites.env" ]] || return 1
  # shellcheck source=/dev/null
  source "${ROOT}/sites.env"
  [[ -n "${SITE_0_INSTANCE_ID:-}" && -n "${SITE_1_INSTANCE_ID:-}" \
     && -n "${SITE_0_TRANSPORT_IP:-}" && -n "${SITE_1_TRANSPORT_IP:-}" ]]
}

guest_up_site() {
  local sid="$1" iid ip out
  sites_env_ready || return 1
  iid="$(site_instance_from_sites "$sid")" || return 1
  ip="10.${sid}.1.10"
  out=$(ssm_run "$iid" x "ping -c1 -W3 ${ip} 2>&1 | grep received || true")
  echo "$out" | grep -q '1 received'
}

guest_up_both() { guest_up_site 0 && guest_up_site 1; }

l2_up_site() {
  local sid="$1" iid ip out
  sites_env_ready || return 1
  iid="$(site_instance_from_sites "$sid")" || return 1
  ip="10.${sid}.1.20"
  out=$(ssm_run "$iid" x "ping -c1 -W3 ${ip} 2>&1 | grep received || true")
  echo "$out" | grep -q '1 received'
}

l2_up_both() { l2_up_site 0 && l2_up_site 1; }

# --- Blocking waits ---

wait_bootstrap_site() {
  local sid="${1:?site id}" iid attempt out
  iid="$(site_instance_from_stack "$sid")"
  wait_ssm_online "$iid"
  _log "wait_bootstrap site${sid} ${iid}"
  for attempt in $(seq 1 50); do
    out=$(ssm_run "$iid" x 'grep BOOTSTRAP.finished /var/log/amazon/launch-timing.log | tail -1 || true')
    if echo "$out" | grep -q 'BOOTSTRAP finished'; then
      _log "bootstrap complete site${sid}"
      return 0
    fi
    _log "  bootstrap site${sid} attempt=${attempt}/50"
    sleep 30
  done
  _log "ERROR bootstrap timeout site${sid}"
  return 1
}

wait_bootstrap_both() {
  local p0 p1 rc=0
  wait_ssm_online_both
  wait_bootstrap_site 0 & p0=$!
  wait_bootstrap_site 1 & p1=$!
  wait "$p0" || rc=1
  wait "$p1" || rc=1
  return "$rc"
}

wait_sites_env() {
  sites_env_ready && return 0
  _log "ERROR sites.env missing — run configure-peer-routing.sh"
  return 1
}

wait_guest_site() {
  local sid="${1:?site id}" iid ip attempt out
  wait_sites_env
  iid="$(site_instance_from_sites "$sid")"
  ip="10.${sid}.1.10"
  wait_ssm_online "$iid"
  _log "wait_guest site${sid} ${ip}"
  for attempt in $(seq 1 45); do
    out=$(ssm_run "$iid" x "ping -c1 -W3 ${ip} 2>&1 | grep received || true")
    if echo "$out" | grep -q '1 received'; then
      _log "guest up site${sid} ${ip}"
      return 0
    fi
    _log "  guest site${sid} attempt=${attempt}/45"
    sleep 60
  done
  return 1
}

wait_guest_both() {
  local rc=0
  wait_guest_site 0 || rc=1
  wait_guest_site 1 || rc=1
  return "$rc"
}

wait_l2_site() {
  local sid="${1:?site id}" iid ip attempt out
  wait_sites_env
  iid="$(site_instance_from_sites "$sid")"
  ip="10.${sid}.1.20"
  wait_ssm_online "$iid"
  _log "wait_l2 site${sid} ${ip}"
  for attempt in $(seq 1 120); do
    out=$(ssm_run "$iid" x \
      "grep -E 'REAL_L2_OK|INNER_UBUNTU_OK' /var/log/nested-virt-inner-deploy.log 2>/dev/null | tail -1; ping -c1 -W3 ${ip} 2>&1 | grep received || true")
    if echo "$out" | grep -q '1 received'; then
      _log "l2 up site${sid} ${ip}"
      return 0
    fi
    _log "  l2 site${sid} attempt=${attempt}/120 (~90s each)"
    sleep 90
  done
  return 1
}

wait_l2_both() {
  local p0 p1 rc=0
  wait_l2_site 0 & p0=$!
  wait_l2_site 1 & p1=$!
  wait "$p0" || rc=1
  wait "$p1" || rc=1
  return "$rc"
}
