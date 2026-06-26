#!/usr/bin/env bash
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"

echo "=== Site 0 (${AVAILABILITY_ZONE_A:-us-east-1a}) ==="
SITE_ID=0 AVAILABILITY_ZONE="${AVAILABILITY_ZONE_A:-us-east-1a}" "${BIN}/run-site.sh"

echo ""
echo "=== Site 1 (${AVAILABILITY_ZONE_B:-us-east-1b}) ==="
SITE_ID=1 AVAILABILITY_ZONE="${AVAILABILITY_ZONE_B:-us-east-1b}" "${BIN}/run-site.sh"

echo ""
echo "=== Peer routing ==="
"${BIN}/configure-peer-routing.sh"

echo ""
echo "Both sites deployed. Run ./bin/invoke-routing-proof.sh when bootstrap completes."
