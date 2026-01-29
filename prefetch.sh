#!/usr/bin/env bash
set -e

# ===== CONFIG =====
BASE_DIR="$(pwd)"
CACHE_DIR="$BASE_DIR/cache"
PACKAGES_FILE="$BASE_DIR/packages.txt"
TMP_DIR="$BASE_DIR/npm-prefetch-tmp"
# ==================

echo "📦 npm offline prefetch starting"
echo "Cache dir : $CACHE_DIR"
echo "Packages  : $PACKAGES_FILE"
echo "--------------------------------------"

mkdir -p "$CACHE_DIR"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

# Force npm to use portable cache
export npm_config_cache="$CACHE_DIR"
export npm_config_progress=false
export npm_config_fund=false
export npm_config_audit=false

cd "$TMP_DIR"

# Init dummy project (explicit name to be extra safe)
npm init -y >/dev/null

INSTALL_PKGS=()

while IFS= read -r pkg || [[ -n "$pkg" ]]; do
  pkg="$(echo "$pkg" | tr -d '\r' | xargs)"
  [[ -z "$pkg" ]] && continue
  [[ "$pkg" =~ ^# ]] && continue

  if [[ "$pkg" != *@* ]]; then
    version=$(npm view "$pkg" dist-tags.latest)
    full_pkg="$pkg@$version"
    echo "📦 $pkg → resolved latest: $full_pkg"
  else
    full_pkg="$pkg"
    echo "📦 Using specified version: $full_pkg"
  fi

  INSTALL_PKGS+=("$full_pkg")
done < "$PACKAGES_FILE"

echo "--------------------------------------"
echo "Installing packages to warm cache..."
echo "--------------------------------------"

# THIS is the important line — pulls full dependency tree
#npm install "${INSTALL_PKGS[@]}" --legacy-peer-deps
npm install @module-federation/vite --legacy-peer-deps
echo "--------------------------------------"
echo "🧹 Cleaning temp project (keeping cache)"
cd "$BASE_DIR"
rm -rf "$TMP_DIR"

echo "--------------------------------------"
echo "✅ Prefetch complete"
du -sh "$CACHE_DIR"
