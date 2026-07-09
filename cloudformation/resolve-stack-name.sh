#!/usr/bin/env bash
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
BASE="${STACK_BASE_NAME:-nested-virt-s0}"

python3 - "$REGION" "$BASE" <<'PY'
import json, re, subprocess, sys

region, base = sys.argv[1], sys.argv[2]
pat = re.compile(rf"^{re.escape(base)}-(\d+)$")

out = subprocess.check_output(
    ["aws", "cloudformation", "list-stacks", "--region", region, "--output", "json"],
    text=True,
)
max_n = 0
for s in json.loads(out).get("StackSummaries", []):
    name = s.get("StackName", "")
    status = s.get("StackStatus", "")
    m = pat.match(name)
    if not m:
        continue
    n = int(m.group(1))
    if status != "DELETE_COMPLETE":
        max_n = max(max_n, n)

print(f"{base}-{max_n + 1:02d}")
PY
