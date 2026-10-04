#!/usr/bin/env bash
# Fail if any layer of a local image looks like it carries a credential.
#
# Nothing secret belongs in a world-readable, effectively permanent layer. This
# is a cheap backstop, not a substitute for not doing it in the first place.
#
# The history is read OUTSIDE any `if`, under `set -e`, so an image that does not
# exist is a hard failure rather than an empty match that passes (CIIMG-14).
#
# Usage: scripts/scan-layer-history.sh <image-ref-or-id>
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: scripts/scan-layer-history.sh <image-ref-or-id>" >&2
  exit 2
fi
ref="$1"

history="$(docker history --no-trunc --format '{{.CreatedBy}}' "$ref")" || {
  echo "::error::could not read the layer history of $ref" >&2
  exit 1
}
if [ -z "$history" ]; then
  echo "::error::layer history of $ref is empty; nothing was scanned" >&2
  exit 1
fi

if grep -inE '(ghp_|github_pat_|-----BEGIN [A-Z ]*PRIVATE KEY)' <<<"$history"; then
  echo "::error::a build layer of $ref appears to contain a credential"
  exit 1
fi
echo "no credential pattern found in $(wc -l <<<"$history") layer history lines of $ref"
