#!/usr/bin/env pwsh
<#
.SYNOPSIS
Downloads npm packages using direct registry API with PowerShell.

.DESCRIPTION
Uses PowerShell Invoke-WebRequest to directly query npm registry
and download tarballs. No npm CLI dependency needed.

.EXAMPLE
pwsh -NoProfile -File ./scripts/pull-tarballs.ps1
#>

Set-StrictMode -Version Latest

# Configuration
$BASE_DIR = (Get-Location).Path
$PACKAGES_FILE = Join-Path $BASE_DIR 'packages.txt'
$TAR_DIR = Join-Path $BASE_DIR 'tarballs'
$REGISTRY = "https://registry.npmjs.org"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "      Downloading NPM Packages - Direct Registry API        " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Read packages
Write-Host "[*] Reading packages.txt..." -ForegroundColor Yellow
$packages = @()
if (Test-Path $PACKAGES_FILE) {
    Get-Content $PACKAGES_FILE | ForEach-Object {
        $line = $_.Trim() -replace "`r", ""
        if ($line -and -not $line.StartsWith('#')) {
            $packages += $line
        }
    }
}

if ($packages.Count -eq 0) {
    Write-Host "[!] No packages found in packages.txt" -ForegroundColor Red
    exit 1
}

Write-Host "[+] Found $($packages.Count) packages to download"
Write-Host ""

# Setup directory
New-Item -ItemType Directory -Path $TAR_DIR -Force -ErrorAction SilentlyContinue | Out-Null

# Download each package
Write-Host "[*] Downloading packages..." -ForegroundColor Yellow
Write-Host ""

$global:success = 0
$global:failed = 0
$global:failedList = @()
$failedList = @()

function Resolve-Version {
    param($metadata, $requestedVersion)
    # If version is missing, 'latest', or contains range characters, try to use the 'latest' dist-tag
    if (-not $requestedVersion -or $requestedVersion -eq 'latest' -or $requestedVersion -match '[\^~<>=*]') {
        if ($metadata.'dist-tags' -and $metadata.'dist-tags'.latest) {
            return $metadata.'dist-tags'.latest
        }
        # Fallback to the highest available version string if latest tag is missing
        $versions = $metadata.versions | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
        if ($versions) {
            return ($versions | Sort-Object -Descending)[0]
        }
    }
    return $requestedVersion
}

$processed = @{}

function Download-Package {
    param($spec)

    # Parse package name and version
    $name = $spec
    $version = $null

    if ($name -match '^@[^/]+/[^@]+@') {
        $lastAt = $name.LastIndexOf('@')
        $version = $name.Substring($lastAt + 1)
        $name = $name.Substring(0, $lastAt)
    } elseif ($name -match '@' -and -not $name.StartsWith('@')) {
        $parts = $name -split '@'
        $name = $parts[0]
        $version = $parts[1]
    }

    $key = "$name@$version"
    if ($processed.ContainsKey($key)) {
        return
    }

    Write-Host "[->] $spec"
    try {
        $encodedName = $name.Replace('/', '%2F')
        $apiUrl = "$REGISTRY/$encodedName"
        Write-Host "   [.] Querying registry..."
        $response = Invoke-WebRequest -Uri $apiUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $metadata = $response.Content | ConvertFrom-Json

        $version = Resolve-Version $metadata $version

        if (-not $metadata.versions -or -not $metadata.versions.$version) {
            Write-Host "   [!] Version $version not found" -ForegroundColor Red
            $global:failed++
            $global:failedList += $spec
            return
        }

        $versionData = $metadata.versions.$version
        if (-not $versionData.dist -or -not $versionData.dist.tarball) {
            Write-Host "   [!] No tarball URL found" -ForegroundColor Red
            $global:failed++
            $global:failedList += $spec
            return
        }

        $tarballUrl = $versionData.dist.tarball
        $filename = "$($name.Replace('/', '-'))-$version.tgz"
        $filepath = Join-Path $TAR_DIR $filename

        if (Test-Path $filepath) {
            Write-Host "   [+] Already have: $filename"
        } else {
            Write-Host "   [v] Downloading from registry..."
            Invoke-WebRequest -Uri $tarballUrl -OutFile $filepath -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop | Out-Null
            $sizeMB = [Math]::Round((Get-Item $filepath).Length / 1MB, 2)
            Write-Host "   [+] Downloaded: $filename ($sizeMB MB)"
            $global:success++
        }

        $processed[$key] = $true

        # Recursively download dependencies (Regular, Peer,)
        $dependencyTypes = @('dependencies', 'peerDependencies',)
        foreach ($depType in $dependencyTypes) {
            if ($versionData | Get-Member -Name $depType -MemberType NoteProperty -ErrorAction SilentlyContinue) {
                $depsObject = $versionData.$depType
                if ($depsObject -is [System.Management.Automation.PSCustomObject]) {
                    $depNames = $depsObject | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
                    if ($depNames) {
                        Write-Host "   [:] Processing $depType..." -ForegroundColor DarkCyan
                        foreach ($depName in $depNames) {
                            $depSpec = "$depName@$($depsObject.$depName)"
                            Download-Package $depSpec
                        }
                    }
                }
            }
        }
    } catch {
        Write-Host "   [!] Error: $($_.Exception.Message)" -ForegroundColor Red
        $global:failed++
        $global:failedList += $spec
    }
}

foreach ($spec in $packages) {
    Download-Package $spec
}

# Summary
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "                    DOWNLOAD COMPLETE                       " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$totalSize = 0
$fileCount = @(Get-ChildItem -Path $TAR_DIR -Filter '*.tgz' -ErrorAction SilentlyContinue).Count

Get-ChildItem -Path $TAR_DIR -Filter '*.tgz' -ErrorAction SilentlyContinue | ForEach-Object {
    $totalSize += $_.Length
}

$sizeMB = [Math]::Round($totalSize / 1MB, 2)

Write-Host "Summary:"
Write-Host "  * Total packages to process: $($packages.Count)"
Write-Host "  * Successfully downloaded unique packages: $success" -ForegroundColor Green
Write-Host "  * Failed to download packages: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($failed -gt 0) {
    Write-Host "[!] Failed packages:" -ForegroundColor Red
    $global:failedList | ForEach-Object { Write-Host "   * $_" }
    Write-Host ""
}

Write-Host "Tarballs directory:"
Write-Host "  * Location: $TAR_DIR"
Write-Host "  * Files: $fileCount"
Write-Host "  * Size: $sizeMB MB"
Write-Host ""

if ($failed -eq 0) {
    Write-Host "[+] SUCCESS! All specified packages and their dependencies downloaded." -ForegroundColor Green
} elseif ($success -gt 0) {
    Write-Host "[!] PARTIAL SUCCESS! Some packages or their dependencies failed to download." -ForegroundColor Yellow
} else {
    Write-Host "[!] FAILURE! No packages were successfully downloaded." -ForegroundColor Red
}

# Generate manifest for GitHub Summary
$manifestPath = Join-Path $BASE_DIR 'downloaded-packages.txt'
if ($processed.Count -gt 0) {
    $processed.Keys | Sort-Object | Out-File -FilePath $manifestPath -Encoding utf8
    Write-Host "[*] Manifest of $($processed.Count) packages created at: $manifestPath" -ForegroundColor Gray
}

Write-Host ""
exit 0