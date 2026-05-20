#!/usr/bin/env bash
set -euo pipefail

PREFERRED_IDENTITY="${CODESIGN_IDENTITY:-CodexQuotaBar Local Signing}"

if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$PREFERRED_IDENTITY\""; then
  echo "$PREFERRED_IDENTITY"
  exit 0
fi

if [[ "${CODESIGN_IDENTITY:-}" == "CodexQuotaBar Local Signing" ]]; then
  echo "ERROR: preferred signing identity 'CodexQuotaBar Local Signing' was not found." >&2
else
  echo "ERROR: requested signing identity '$CODESIGN_IDENTITY' was not found." >&2
fi
echo "Available code signing identities on this Mac:" >&2
security find-identity -v -p codesigning || true
exit 1
