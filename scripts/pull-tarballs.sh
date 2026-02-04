#!/usr/bin/env bash
set -euo pipefail

# Pull package tarballs (and dependencies) for packages listed in packages.txt
# Produces tarballs/ directory with unique .tgz files for each resolved package
# Usage: ./scripts/pull-tarballs.sh
# Optional env vars:
#  - PACKAGES_FILE (defaults to ./packages.txt)
#  - TAR_DIR (defaults to ./tarballs)
#  - TMP_DIR (defaults to ./npm-pull-tarballs-tmp)

BASE_DIR="$(pwd)"
PACKAGES_FILE="${PACKAGES_FILE:-$BASE_DIR/packages.txt}"
TMP_DIR="${TMP_DIR:-$BASE_DIR/npm-pull-tarballs-tmp}"
TAR_DIR="${TAR_DIR:-$BASE_DIR/tarballs}"

echo "🔽 Pulling tarballs for packages listed in $PACKAGES_FILE"

command -v node >/dev/null 2>&1 || { echo "Node.js is required" >&2; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "npm is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || { echo "curl or wget is required" >&2; exit 1; }

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
mkdir -p "$TAR_DIR"
cd "$TMP_DIR"

# Init a minimal project to generate a package-lock.json
npm init -y >/dev/null

INSTALL_PKGS=()
while IFS= read -r pkg || [[ -n "$pkg" ]]; do
  pkg="$(echo "$pkg" | tr -d '\r' | xargs)"
  [[ -z "$pkg" ]] && continue
  [[ "$pkg" =~ ^# ]] && continue

  if [[ "$pkg" != *@* ]]; then
    version=$(npm view "$pkg" dist-tags.latest 2>/dev/null || true)
    if [[ -z "$version" ]]; then
      echo "⚠️  Could not resolve latest version for $pkg; adding as-is"
      full_pkg="$pkg"
    else
      full_pkg="$pkg@$version"
      echo "📦 $pkg → resolved latest: $full_pkg"
    fi
  else
    full_pkg="$pkg"
    echo "📦 Using specified version: $full_pkg"
  fi

  INSTALL_PKGS+=("$full_pkg")
done < "$PACKAGES_FILE"

if [ ${#INSTALL_PKGS[@]} -eq 0 ]; then
  echo "No packages found in $PACKAGES_FILE" >&2
  exit 1
fi

# Generate lock file (does not download tarballs)
npm install "${INSTALL_PKGS[@]}" --package-lock-only --legacy-peer-deps >/dev/null

# Extract package-name, version, and resolved URLs from package-lock.json using Node (portable)
# Output format: tab-separated lines: <name>\t<version>\t<resolved-url> (one per line)
RESOLVED_TSV="$TMP_DIR/resolved_pkgs.tsv"
node <<'NODE' > "$RESOLVED_TSV"
const fs = require('fs');
let p;
try {
  p = JSON.parse(fs.readFileSync('package-lock.json','utf8'));
} catch (e) {
  // no lockfile or parse error
  process.exit(0);
}
const lines = [];
function addLine(name, version, resolved){
  if(resolved && typeof resolved === 'string'){
    lines.push([name || '', version || '', resolved].join('\t'));
  }
}
// npm v2+ lock has a "packages" map
if(p.packages && typeof p.packages === 'object'){
  for(const node of Object.values(p.packages)){
    if(node && node.name && node.version && node.resolved){
      addLine(node.name, node.version, node.resolved);
    }
  }
}
// also walk dependencies recursively to catch older lock formats
function walkDeps(obj){
  if(!obj || typeof obj !== 'object') return;
  for(const [name, node] of Object.entries(obj)){
    if(node && node.resolved){
      addLine(name, node.version || '', node.resolved);
    }
    if(node && node.dependencies) walkDeps(node.dependencies);
  }
}
if(p.dependencies) walkDeps(p.dependencies);
// remove duplicates (keep first)
const seen = new Set();
const out = [];
for(const l of lines){
  if(!l) continue;
  const key = (l.split('\t')[2] || l);
  if(seen.has(key)) continue;
  seen.add(key);
  out.push(l);
}
process.stdout.write(out.join('\n'));
NODE

# Helper: downloader that works on Windows Git Bash (curl/wget/powershell fallback)
download_file(){
  local url="$1" dest="$2"
  tmp_dest="$dest.tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail -sS -o "$tmp_dest" "$url" || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$tmp_dest" "$url" || return 1
  else
    # Use PowerShell on Windows runners if available
    if command -v pwsh >/dev/null 2>&1; then
      # pwsh prefers Windows-style paths on some setups
      if command -v cygpath >/dev/null 2>&1; then
        win_dest="$(cygpath -w "$dest")"
      else
        win_dest="$dest"
      fi
      pwsh -NoProfile -Command "try { Invoke-WebRequest -Uri '$url' -OutFile '$win_dest' -UseBasicParsing } catch { exit 1 }" >/dev/null 2>&1 || return 1
      # If pwsh wrote the file, ensure it's visible at $dest (pwsh may have used a different path format)
      if [ -f "$win_dest" ] && [ "$win_dest" != "$dest" ]; then
        mv "$win_dest" "$dest" >/dev/null 2>&1 || true
      fi
    elif command -v powershell >/dev/null 2>&1; then
      if command -v cygpath >/dev/null 2>&1; then
        win_dest="$(cygpath -w "$dest")"
      else
        win_dest="$dest"
      fi
      powershell -NoProfile -Command "try { Invoke-WebRequest -Uri '$url' -OutFile '$win_dest' -UseBasicParsing } catch { exit 1 }" >/dev/null 2>&1 || return 1
      if [ -f "$win_dest" ] && [ "$win_dest" != "$dest" ]; then
        mv "$win_dest" "$dest" >/dev/null 2>&1 || true
      fi
    else
      echo "No downloader available (curl, wget, pwsh, or powershell required)" >&2
      return 1
    fi
  fi
  # if we used curl/wget, move tmp to final
  if [ -f "$tmp_dest" ]; then
    mv "$tmp_dest" "$dest"
  fi
}

# Filter and download (tab-separated: name\tversion\turl)
count=0
while IFS=$'\t' read -r name version url || [[ -n "$name" ]]; do
  [[ -z "$url" ]] && continue
  # skip non-http(s)
  if [[ ! "$url" =~ ^https?:// ]]; then
    echo "Skipping non-HTTP resolved entry for $name@$version: $url"
    continue
  fi
  # derive a stable filename: sanitize name and append version
  sanitized_name="$(echo "$name" | sed 's|/|-|g; s|@||g; s|[^a-zA-Z0-9._-]|-|g')"
  short_url="${url%%\?*}"
  orig_fname="$(basename "$short_url")"
  dest="$TAR_DIR/${sanitized_name}-${version}.tgz"
  if [ -f "$dest" ]; then
    echo "⏭️  Already have $(basename "$dest"); skipping"
    continue
  fi
  echo "⬇️  Downloading $name@$version → $dest"
  if download_file "$url" "$dest"; then
    count=$((count+1))
  else
    echo "⚠️  Failed to download $url; will attempt npm pack fallback for $name@$version"
  fi
done < "$RESOLVED_TSV"

# npm pack fallback for packages that may not have a tarball or failed download
for pkg in "${INSTALL_PKGS[@]}"; do
  # compute basic sanitized filename expected from pack
  basepkg="${pkg%%#*}"
  # strip possible version spec for checking
  shortname="${basepkg%@*}"
  sanitized_name="$(echo "$shortname" | sed 's|/|-|g; s|@||g; s|[^a-zA-Z0-9._-]|-|g')"
  version=""
  if [[ "$basepkg" == *"@"* ]]; then
    version="${basepkg##*@}"
  fi
  dest="$TAR_DIR/${sanitized_name}-${version}.tgz"
  if [ -f "$dest" ]; then
    continue
  fi
  echo "🧩 Attempting npm pack fallback for $pkg"
  if npm pack "$pkg" >/dev/null 2>&1; then
    # move most recent .tgz from tmp dir to TAR_DIR
    tgzfile=$(ls -1t ./*.tgz 2>/dev/null | head -n1 || true)
    if [ -n "$tgzfile" ]; then
      mv "$tgzfile" "$TAR_DIR/" || echo "Could not move $tgzfile"
      echo "📦 Packed $tgzfile"
      count=$((count+1))
    fi
  else
    echo "npm pack failed or produced no tarball for $pkg"
  fi
done

echo "--------------------------------------"
echo "✅ Tarball fetch complete. New downloads: $count"
echo "Tarballs are in: $TAR_DIR"
ls -1 "$TAR_DIR" || true

# cleanup
cd "$BASE_DIR"
rm -rf "$TMP_DIR"

exit 0
