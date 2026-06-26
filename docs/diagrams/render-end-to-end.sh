#!/usr/bin/env bash
# Regenerate README PNG from end-to-end.svg (run after any SVG edit).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SVG="${DIR}/end-to-end.svg"
PNG="${DIR}/end-to-end.png"
RSVG="${RSVG_CONVERT:-rsvg-convert}"

if ! command -v "${RSVG}" >/dev/null 2>&1; then
  echo "error: ${RSVG} not found (brew install librsvg)" >&2
  exit 1
fi

"${RSVG}" -w 1600 -f png -o "${PNG}" "${SVG}"
echo "Wrote ${PNG} from ${SVG}"
