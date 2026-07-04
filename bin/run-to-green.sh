#!/usr/bin/env bash
# Deprecated — use ./bin/go.sh
exec "$(cd "$(dirname "$0")" && pwd)/go.sh" "$@"
