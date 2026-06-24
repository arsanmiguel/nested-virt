#!/bin/bash
set -euo pipefail
TIMING_LOG=/var/log/amazon/launch-timing.log
BOOTSTRAP_DIR=/var/lib/nested-virt
BOOTSTRAP_SCRIPT=${BOOTSTRAP_DIR}/bootstrap.sh
BUCKET='{{BOOTSTRAP_BUCKET}}'
KEY='nested-virt/bootstrap.sh'

log() { echo "$(date -Iseconds) STUB $*" | tee -a "$TIMING_LOG"; }

mkdir -p /var/log/amazon "$BOOTSTRAP_DIR"
log 'begin'

REGION=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' | \
  xargs -I{} curl -sf -H "X-aws-ec2-metadata-token: {}" \
  http://169.254.169.254/latest/meta-data/placement/region)
log "region=${REGION}"

command -v aws >/dev/null 2>&1 || dnf install -y awscli
log "s3 cp begin s3://${BUCKET}/${KEY}"
aws s3 cp "s3://${BUCKET}/${KEY}" "$BOOTSTRAP_SCRIPT" --region "$REGION"
chmod +x "$BOOTSTRAP_SCRIPT"
log "s3 cp done dest=${BOOTSTRAP_SCRIPT} size=$(stat -c%s "$BOOTSTRAP_SCRIPT")"
log 'bootstrap invoke begin'
exec "$BOOTSTRAP_SCRIPT"
