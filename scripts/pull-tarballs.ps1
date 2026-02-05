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
$PACKAGES_FILE = $env:PACKAGES_FILE -or (Join-Path $BASE_DIR 'packages.txt')
$TMP_DIR = $env:TMP_DIR -or (Join-Path $BASE_DIR 'npm-pull-tarballs-tmp')
$TAR_DIR = $env:TAR_DIR -or (Join-Path $BASE_DIR 'tarballs')

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
$RESOLVED_TSV = Join-Path $TMP_DIR 'resolved_pkgs.tsv'
$nodeScript = @'
const fs = require('fs');
let p;
try { p = JSON.parse(fs.readFileSync('package-lock.json','utf8')); } catch(e){ process.exit(0); }
const lines = [];
function addLine(name, version, resolved){ if(resolved && typeof resolved === 'string'){ lines.push([name || '', version || '', resolved].join('\t')); }}
if(p.packages && typeof p.packages === 'object'){
  for(const node of Object.values(p.packages)){
    if(node && node.name && node.version && node.resolved){ addLine(node.name, node.version, node.resolved); }
  }
}
function walkDeps(obj){ if(!obj || typeof obj !== 'object') return; for(const [name, node] of Object.entries(obj)){ if(node && node.resolved){ addLine(name, node.version || '', node.resolved); } if(node && node.dependencies) walkDeps(node.dependencies); }}
if(p.dependencies) walkDeps(p.dependencies);
const seen = new Set(); const out = [];
for(const l of lines){ if(!l) continue; const key = (l.split('\t')[2] || l); if(seen.has(key)) continue; seen.add(key); out.push(l); }
process.stdout.write(out.join('\n'));
'@

Set-Content -Path (Join-Path $TMP_DIR 'dumped-node-script.js') -Value $nodeScript -NoNewline
& node (Join-Path $TMP_DIR 'dumped-node-script.js') | Out-File -FilePath $RESOLVED_TSV -Encoding utf8

function Download-File([string]$url, [string]$dest) {
    Try {
        if (Get-Command curl -ErrorAction SilentlyContinue) {
            & curl -L --fail -sS -o $dest $url
        } elseif (Get-Command wget -ErrorAction SilentlyContinue) {
            & wget -q -O $dest $url
        } else {
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
        }
        return $true
    } catch {
        return $false
    }
}

$count = 0
if (Test-Path $RESOLVED_TSV) {
    Get-Content -Path $RESOLVED_TSV -ErrorAction SilentlyContinue | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { return }
        $parts = $_ -split "\t"
        $name = $parts[0]
        $version = $parts[1]
        $url = $parts[2]
        if ([string]::IsNullOrWhiteSpace($url)) { return }
        if ($url -notmatch '^https?://') { Write-Host "Skipping non-HTTP resolved entry for ${name}@${version}: ${url}"; return }
        $sanitized_name = ($name -replace '/','-' -replace '@','' -replace '[^a-zA-Z0-9._-]','-')
        $short_url = $url -split '\?' | Select-Object -First 1
        $dest = Join-Path $TAR_DIR ("$($sanitized_name)-$version.tgz")
        if (Test-Path $dest) { Write-Host "⏭️  Already have $(Split-Path $dest -Leaf); skipping"; return }
        Write-Host "⬇️  Downloading ${name}@${version} → $dest"
        if (Download-File $url $dest) { $count += 1 } else { Write-Host "⚠️  Failed to download ${url}; will attempt npm pack fallback for ${name}@${version}" }
    }
}

# npm pack fallback for packages that may not have a tarball or failed download
foreach ($pkg in $INSTALL_PKGS) {
    $basepkg = ($pkg -split '#')[0]
    if ($basepkg -match '@') { $shortname = ($basepkg -split '@')[0] } else { $shortname = $basepkg }
    $sanitized_name = ($shortname -replace '/','-' -replace '@','' -replace '[^a-zA-Z0-9._-]','-')
    $version = ''
    if ($basepkg -match '@') { $version = ($basepkg -split '@')[-1] }
    $dest = Join-Path $TAR_DIR ("$($sanitized_name)-$version.tgz")
    if (Test-Path $dest) { continue }
    Write-Host "🧩 Attempting npm pack fallback for $pkg"
    $packOk = $false
    try {
        & npm pack $pkg | Out-Null
        $packOk = $true
    } catch { $packOk = $false }
    if ($packOk) {
        $tgzfile = Get-ChildItem -Path (Get-Location) -Filter '*.tgz' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($tgzfile) {
            Try { Move-Item -Path $tgzfile.FullName -Destination $TAR_DIR -Force; Write-Host "📦 Packed $($tgzfile.Name)"; $count += 1 } Catch { Write-Host "Could not move $($tgzfile.Name)" }
        }
    } else {
        Write-Host "npm pack failed or produced no tarball for $pkg"
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
