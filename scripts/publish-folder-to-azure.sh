#!/usr/bin/env bash
set -euo pipefail

# Publish all *.tgz files from a folder to an Azure DevOps npm feed
# Usage: ./scripts/publish-folder-to-azure.sh /path/to/extracted-tarballs [--dry-run]
# Required env vars:
#  - AZURE_REGISTRY: e.g. https://pkgs.dev.azure.com/ORG/_packaging/FEED/npm/registry/
# Optional env vars:
#  - NPM_TOKEN: personal access token with packaging (publish) scope

DRY_RUN=false
if [ "${2:-}" = "--dry-run" ] || [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
fi

DIR="${1:-}"
if [ -z "$DIR" ] || [ "$DIR" = "--dry-run" ]; then
  echo "Usage: $0 /path/to/tarballs [--dry-run]" >&2
  exit 1
fi

if [ ! -d "$DIR" ]; then
  echo "Directory not found: $DIR" >&2
  exit 1
fi

if [ -z "${AZURE_REGISTRY:-}" ]; then
  echo "AZURE_REGISTRY must be set (ex: https://pkgs.dev.azure.com/ORG/_packaging/FEED/npm/registry/)" >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required to publish packages" >&2
  exit 1
fi

TGZ_COUNT=$(shopt -s nullglob; tmp=("$DIR"/*.tgz); echo ${#tmp[@]}; shopt -u nullglob)
if [ "$TGZ_COUNT" -eq 0 ]; then
  echo "No .tgz files found in $DIR" >&2
  exit 1
fi

TMP_NPMRC=""
NPMRC_SET=false
if [ -n "${NPM_TOKEN:-}" ]; then
  # Create a temporary .npmrc for auth (do not persist)
  TMP_NPMRC="$(mktemp)"
  # remove protocol and trailing slash for host mapping
  host=$(echo "$AZURE_REGISTRY" | sed -E 's#^https?://##' | sed -E 's#/$##')
  # Write auth and registry
  echo "//${host}:_authToken=${NPM_TOKEN}" > "$TMP_NPMRC"
  echo "registry=${AZURE_REGISTRY}" >> "$TMP_NPMRC"
  NPMRC_SET=true
  echo "Using temporary .npmrc for authentication"
else
  echo "NPM_TOKEN not set — will rely on existing npm auth (npm login)"
fi

SUCCESSES=()
FAILURES=()

for pkg in "$DIR"/*.tgz; do
  [ -e "$pkg" ] || continue
  echo "Publishing: $pkg"
  if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: npm publish \"$pkg\" --registry $AZURE_REGISTRY"
    SUCCESSES+=("$pkg (dry)")
    continue
  fi

  if [ "$NPMRC_SET" = true ]; then
    if npm publish "$pkg" --registry "$AZURE_REGISTRY" --userconfig "$TMP_NPMRC"; then
      SUCCESSES+=("$pkg")
    else
      echo "Failed to publish $pkg" >&2
      FAILURES+=("$pkg")
    fi
  else
    if npm publish "$pkg" --registry "$AZURE_REGISTRY"; then
      SUCCESSES+=("$pkg")
    else
      echo "Failed to publish $pkg" >&2
      FAILURES+=("$pkg")
    fi
  fi
done

# cleanup
if [ -n "$TMP_NPMRC" ]; then
  rm -f "$TMP_NPMRC" || true
fi

echo "--------------------------------------"
echo "Publish summary:"
echo "  Successes: ${#SUCCESSES[@]}"
for s in "${SUCCESSES[@]}"; do echo "   - $s"; done
if [ ${#FAILURES[@]} -ne 0 ]; then
  echo "  Failures: ${#FAILURES[@]}"
  for f in "${FAILURES[@]}"; do echo "   - $f"; done
  exit 2
fi

echo "✅ All packages published successfully (or dry-run)"
exit 0
