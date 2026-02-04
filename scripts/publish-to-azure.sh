#!/usr/bin/env bash
set -euo pipefail

# Publish downloaded tarballs to an Azure DevOps npm feed
# Requirements:
# - NPM_TOKEN (or npm login already configured) with publish permissions
# - AZURE_REGISTRY (npm registry URL for the feed), e.g. https://pkgs.dev.azure.com/ORG/_packaging/FEED/npm/registry/
# - TAR_DIR (defaults to ./tarballs)

TAR_DIR="${TAR_DIR:-$(pwd)/tarballs}"
AZURE_REGISTRY="${AZURE_REGISTRY:-}" # required

if [ -z "$AZURE_REGISTRY" ]; then
  echo "AZURE_REGISTRY must be set, e.g. https://pkgs.dev.azure.com/ORG/_packaging/FEED/npm/registry/" >&2
  exit 1
fi

if [ -z "${NPM_TOKEN:-}" ]; then
  echo "Warning: NPM_TOKEN not set; publishing will rely on existing npm auth config" >&2
fi

# create a temporary .npmrc to publish with token (do not persist)
TMP_NPMRC="$(mktemp)"
if [ -n "${NPM_TOKEN:-}" ]; then
  # If registry is Azure DevOps, registry URL for token usage differs slightly; using npm's auth format
  echo "//${AZURE_REGISTRY#https://}:_authToken=${NPM_TOKEN}" > "$TMP_NPMRC"
  echo "registry=${AZURE_REGISTRY}" >> "$TMP_NPMRC"
  NPMRC_SET=true
else
  NPMRC_SET=false
fi

pushd "$TAR_DIR" >/dev/null

for pkg in ./*.tgz; do
  [ -e "$pkg" ] || { echo "No tarballs found in $TAR_DIR"; break; }
  echo "📤 Publishing $pkg to $AZURE_REGISTRY"
  if [ "$NPMRC_SET" = true ]; then
    npm publish "$pkg" --registry "$AZURE_REGISTRY" --userconfig "$TMP_NPMRC"
  else
    npm publish "$pkg" --registry "$AZURE_REGISTRY"
  fi
done

popd >/dev/null

# cleanup
rm -f "$TMP_NPMRC" || true

echo "✅ Publish complete"
