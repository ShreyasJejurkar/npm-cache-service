#!/usr/bin/env bash
set -e

# ---------- helpers ----------
to_win_path() {
  cygpath -w "$1"
}

# ---------- config ----------
BASE_DIR="$(pwd)"
CACHE_DIR_UNIX="$BASE_DIR/cache"
CACHE_DIR_WIN="$(to_win_path "$CACHE_DIR_UNIX")"
PACKAGES_FILE="$BASE_DIR/packages.txt"

echo "🔍 Verifying npm offline cache"
echo "Cache folder: $CACHE_DIR_UNIX"
echo "--------------------------------------"

# Temporary project for dry-run
TMP_DIR="$BASE_DIR/npm-verify-tmp"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
cd "$TMP_DIR"
npm init -y >/dev/null

# Use offline cache
export npm_config_cache="$CACHE_DIR_WIN"
export npm_config_progress=false
export npm_config_fund=false
export npm_config_audit=false

MISSING_PKGS=()

while IFS= read -r pkg || [[ -n "$pkg" ]]; do
  pkg="$(echo "$pkg" | tr -d '\r' | xargs)"
  [[ -z "$pkg" ]] && continue
  [[ "$pkg" =~ ^# ]] && continue

  if [[ "$pkg" != *@* ]]; then
    version=$(npm view "$pkg" dist-tags.latest 2>/dev/null || true)
    [[ -z "$version" ]] && version="UNKNOWN"
    full_pkg="$pkg@$version"
  else
    full_pkg="$pkg"
  fi

  echo -n "Testing $full_pkg ... "

  # Dry-run offline install (does not modify node_modules)
  if npm install "$full_pkg" --offline --prefer-offline --ignore-scripts --no-audit >/dev/null 2>&1; then
    echo "✅ OK"
  else
    echo "❌ MISSING"
    MISSING_PKGS+=("$full_pkg")
  fi
done < "$PACKAGES_FILE"

cd "$BASE_DIR"
rm -rf "$TMP_DIR"

echo "--------------------------------------"
if [ ${#MISSING_PKGS[@]} -eq 0 ]; then
  echo "🎯 All packages and dependencies are present in cache!"
else
  echo "⚠️  The following packages are missing or incomplete in cache:"
  for pkg in "${MISSING_PKGS[@]}"; do
    echo "   - $pkg"
  done
  echo "💡 Re-run prefetch.sh to ensure full dependency tree is cached."
fi
echo "--------------------------------------"
