#!/usr/bin/env bash
# Force fresh Hyper-V inner Ubuntu deploy (new disk + static/DHCP seed).
set -euo pipefail
SITE_ID="${1:-0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export SITE_ID FORCE_REINSTALL=1 UBUNTU_RELEASE="${UBUNTU_RELEASE:-24.04}" PS1_SRC="${SCRIPT_DIR}/provision-ubuntu-inner-vm.ps1"
exec env SCRIPT_DIR="$SCRIPT_DIR" "${SCRIPT_DIR}/deploy-inner-ubuntu-on-host.sh"
