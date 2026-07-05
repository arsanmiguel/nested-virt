#!/usr/bin/env bash
# Deprecated alias — use cloudformation/publish-release.sh (CI/maintainer only).
exec "$(cd "$(dirname "$0")/.." && pwd)/cloudformation/publish-release.sh" "$@"
