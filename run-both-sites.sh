#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "=== Site 0 (${AVAILABILITY_ZONE_A:-us-east-1a}) ==="
SITE_ID=0 AVAILABILITY_ZONE="${AVAILABILITY_ZONE_A:-us-east-1a}" "${ROOT}/run-site.sh"

echo ""
echo "=== Site 1 (${AVAILABILITY_ZONE_B:-us-east-1b}) ==="
SITE_ID=1 AVAILABILITY_ZONE="${AVAILABILITY_ZONE_B:-us-east-1b}" "${ROOT}/run-site.sh"

echo ""
echo "=== Peer routing ==="
"${ROOT}/configure-peer-routing.sh"

echo ""
echo "Both sites deployed. Run ./invoke-routing-proof.sh when bootstrap completes."
