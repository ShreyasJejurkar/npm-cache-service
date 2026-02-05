#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pull package tarballs (and dependencies) for packages listed in packages.txt
# Produces tarballs/ directory with unique .tgz files for each resolved package
# Usage: pwsh -NoProfile -File ./scripts/pull-tarballs.ps1
# Optional env vars:
#  - PACKAGES_FILE (defaults to ./packages.txt)
#  - TAR_DIR (defaults to ./tarballs)
#  - TMP_DIR (defaults to ./npm-pull-tarballs-tmp)

$BASE_DIR = (Get-Location).Path
if (-not [string]::IsNullOrEmpty($env:PACKAGES_FILE)) { $PACKAGES_FILE = $env:PACKAGES_FILE } else { $PACKAGES_FILE = Join-Path $BASE_DIR 'packages.txt' }
if (-not [string]::IsNullOrEmpty($env:TMP_DIR)) { $TMP_DIR = $env:TMP_DIR } else { $TMP_DIR = Join-Path $BASE_DIR 'npm-pull-tarballs-tmp' }
if (-not [string]::IsNullOrEmpty($env:TAR_DIR)) { $TAR_DIR = $env:TAR_DIR } else { $TAR_DIR = Join-Path $BASE_DIR 'tarballs' }

Write-Host "🔽 Pulling tarballs for packages listed in $PACKAGES_FILE"

if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Error "Node.js is required"; exit 1 }
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { Write-Error "npm is required"; exit 1 }

# Ensure cleanup and directories
if (Test-Path $TMP_DIR) { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $TMP_DIR }
New-Item -ItemType Directory -Force -Path $TMP_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $TAR_DIR | Out-Null
Push-Location $TMP_DIR

# Init minimal project to generate package-lock.json
& npm init -y | Out-Null

$INSTALL_PKGS = @()
Get-Content -Path $PACKAGES_FILE -ErrorAction Stop | ForEach-Object {
    $line = $_.Trim() -replace "`r",""
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    if ($line.StartsWith('#')) { return }
    $pkg = $line
    if ($pkg -notmatch '@') {
        $version = $null
        try {
            $version = (& npm view $pkg dist-tags.latest) -join "" | Out-String
            $version = $version.Trim()
        } catch { $version = $null }
        if ([string]::IsNullOrWhiteSpace($version)) {
            Write-Host "⚠️  Could not resolve latest version for $pkg; adding as-is"
            $full_pkg = $pkg
        } else {
            $full_pkg = "${pkg}@${version}"
            Write-Host "📦 $pkg → resolved latest: $full_pkg"
        }
    } else {
        $full_pkg = $pkg
        Write-Host "📦 Using specified version: $full_pkg"
    }
    $INSTALL_PKGS += $full_pkg
}

if ($INSTALL_PKGS.Count -eq 0) { Write-Error "No packages found in $PACKAGES_FILE"; Pop-Location; exit 1 }

# Generate lock file (does not download tarballs)
& npm install $INSTALL_PKGS --package-lock-only --legacy-peer-deps | Out-Null

# Extract resolved URLs using a small Node script (portable)
# Build a unique list of packages@version from package-lock.json and use `npm pack` to fetch tarballs
$PKG_LIST = Join-Path $TMP_DIR 'pkg_list.txt'
$nodeScript = @'
const fs = require('fs');
let p;
try { p = JSON.parse(fs.readFileSync('package-lock.json','utf8')); } catch(e){ process.exit(0); }
const lines = [];
function add(name, version){ if(name && version){ lines.push(name + '\t' + version); }}
if(p.packages && typeof p.packages === 'object'){
  for(const node of Object.values(p.packages)){
    if(node && node.name && node.version){ add(node.name, node.version); }
  }
}
function walkDeps(obj){ if(!obj || typeof obj !== 'object') return; for(const [name, node] of Object.entries(obj)){ if(node && node.version){ add(name, node.version); } if(node && node.dependencies) walkDeps(node.dependencies); }}
if(p.dependencies) walkDeps(p.dependencies);
const seen = new Set(); const out = [];
for(const l of lines){ const key = l; if(seen.has(key)) continue; seen.add(key); out.push(l); }
process.stdout.write(out.join('\n'));
'@

Set-Content -Path (Join-Path $TMP_DIR 'dumped-node-script.js') -Value $nodeScript -NoNewline
& node (Join-Path $TMP_DIR 'dumped-node-script.js') | Out-File -FilePath $PKG_LIST -Encoding utf8

$count = 0
if (Test-Path $PKG_LIST) {
    Get-Content -Path $PKG_LIST -ErrorAction SilentlyContinue | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { return }
        $parts = $_ -split "\t"
        $name = $parts[0]
        $version = $parts[1]
        $pkgSpec = if ([string]::IsNullOrWhiteSpace($version)) { $name } else { "${name}@${version}" }
        $sanitized_name = ($name -replace '/','-' -replace '@','' -replace '[^a-zA-Z0-9._-]','-')
        $dest = Join-Path $TAR_DIR ("$($sanitized_name)-$version.tgz")
        if (Test-Path $dest) { Write-Host "⏭️  Already have $(Split-Path $dest -Leaf); skipping"; return }
        Write-Host "🧩 npm pack $pkgSpec"
        try {
            & npm pack $pkgSpec | Out-Null
            $tgzfile = Get-ChildItem -Path (Get-Location) -Filter '*.tgz' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($tgzfile) {
                Move-Item -Path $tgzfile.FullName -Destination $dest -Force
                Write-Host "📦 Packed $($tgzfile.Name)"
                $count += 1
            }
        } catch {
            Write-Host "npm pack failed for $pkgSpec"
        }
    }
}

Write-Host "--------------------------------------"
Write-Host "✅ Tarball fetch complete. New downloads: $count"
Write-Host "Tarballs are in: $TAR_DIR"
Get-ChildItem -Path $TAR_DIR -Name -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }

# cleanup
Pop-Location
if (Test-Path $TMP_DIR) { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $TMP_DIR }

exit 0
