#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/build-info.env"
mkdir -p "$(dirname "$OUT")"

BUILD_TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
BUILD_EPOCH="$(date '+%Y%m%d%H%M%S')"

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)"
else
  GIT_SHA=""
fi

if [[ -z "$GIT_SHA" ]]; then
  BUILD_ID="$BUILD_EPOCH"
else
  BUILD_ID="$GIT_SHA-$BUILD_EPOCH"
fi

cat > "$OUT" <<EOF
BUILD_ID='$BUILD_ID'
BUILD_TIMESTAMP='$BUILD_TIMESTAMP'
EOF

echo "$OUT"
