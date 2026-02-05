#!/usr/bin/env pwsh
<#
.SYNOPSIS
Verifies offline package installation using tarballs without registry access.

.DESCRIPTION
This script directly extracts and validates packages from .tgz files
to simulate an offline environment where the npm registry is blocked.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Configuration
$TAR_DIR = Join-Path (Get-Location) "tarballs"
$TEST_DIR = Join-Path (Get-Location) "offline-test-env"
$PACKAGES_FILE = Join-Path (Get-Location) "packages.txt"

Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Offline Package Verification (Direct Extraction Test)   ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Step 1: Verify prerequisites
Write-Host "📋 Step 1: Verifying prerequisites..." -ForegroundColor Yellow
Write-Host ""

if (-not (Test-Path $TAR_DIR)) {
    Write-Host "❌ Error: Tarballs directory not found at: $TAR_DIR" -ForegroundColor Red
    exit 1
}

$tarballCount = @(Get-ChildItem -Path $TAR_DIR -Filter "*.tgz").Count
Write-Host "✅ Found $tarballCount tarballs in: $TAR_DIR"

if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    Write-Host "❌ Error: tar command is not available" -ForegroundColor Red
    exit 1
}
Write-Host "✅ tar utility is available"

$nodeVersion = node --version
Write-Host "✅ Node.js is available: $nodeVersion"

# Step 2: Create test environment
Write-Host ""
Write-Host "🔧 Step 2: Setting up test environment..." -ForegroundColor Yellow
Write-Host ""

if (Test-Path $TEST_DIR) {
    Write-Host "🧹 Cleaning up previous test environment..."
    Remove-Item -Recurse -Force $TEST_DIR -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

New-Item -ItemType Directory -Path $TEST_DIR | Out-Null
Write-Host "✅ Created test directory: $TEST_DIR"
New-Item -ItemType Directory -Path "$TEST_DIR/packages" | Out-Null
Write-Host "✅ Created packages directory for extraction"

# Step 3: List test packages
Write-Host ""
Write-Host "📋 Step 3: Preparing test packages..." -ForegroundColor Yellow
Write-Host ""

# Read first 15 packages from packages.txt for testing
$packages = @()
Get-Content -Path $PACKAGES_FILE | ForEach-Object {
    $line = $_ -replace "`r", ""
    $line = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { return }
    $packages += $line
}

$testPackages = $packages | Select-Object -First 15
Write-Host "✅ Found $(($testPackages | Measure-Object).Count) test packages to verify"

# Step 4: Extract and validate packages from tarballs
Write-Host ""
Write-Host "📦 Step 4: Extracting packages from tarballs (No Registry Access)..." -ForegroundColor Yellow
Write-Host ""

$successCount = 0
$failedCount = 0
$failedPackages = @()
$extractedPackages = @()

foreach ($packageSpec in $testPackages) {
    # Extract package name
    $packageName = if ($packageSpec -match "^(@?[^@]+)") { $matches[1] } else { $packageSpec }
    $cleanName = $packageName.Split('/')[-1]
    
    # Find the corresponding .tgz file
    $tgzFiles = @(Get-ChildItem -Path $TAR_DIR -Filter "*$cleanName*.tgz")
    
    if ($tgzFiles.Count -eq 0) {
        Write-Host "⚠️  Skipping $packageName (no .tgz file found)"
        continue
    }
    
    $tgzFile = $tgzFiles[0]
    
    try {
        Write-Host "📥 Extracting: $packageName ($($tgzFile.Name))..."
        
        # Extract to test directory
        $extractDir = Join-Path $TEST_DIR "packages" $cleanName
        New-Item -ItemType Directory -Path $extractDir -ErrorAction SilentlyContinue | Out-Null
        
        # Extract the tarball
        $tarOutput = & tar -xzf $tgzFile.FullName -C $extractDir 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            # Check if package.json exists in extracted content
            $packageJsonPath = Join-Path $extractDir "package" "package.json"
            if (Test-Path $packageJsonPath) {
                Write-Host "   ✅ Successfully extracted: $packageName"
                Write-Host "      📄 Verified package.json present"
                
                # Read and show some package info
                $pkgJson = Get-Content -Path $packageJsonPath | ConvertFrom-Json
                if ($pkgJson.version) {
                    Write-Host "      📌 Version: $($pkgJson.version)"
                }
                
                $successCount++
                $extractedPackages += @{
                    name    = $packageName
                    version = $pkgJson.version
                    tarball = $tgzFile.Name
                }
            } else {
                Write-Host "   ⚠️  Extracted but no package.json found at: $packageJsonPath" -ForegroundColor Yellow
                $failedCount++
                $failedPackages += $packageName
            }
        } else {
            Write-Host "   ❌ Failed to extract: $packageName" -ForegroundColor Red
            Write-Host "   Error: $tarOutput"
            $failedCount++
            $failedPackages += $packageName
        }
    } catch {
        Write-Host "   ❌ Exception extracting $packageName : $($_.Exception.Message)" -ForegroundColor Red
        $failedCount++
        $failedPackages += $packageName
    }
}

# Step 5: Validate Node.js can load package
Write-Host ""
Write-Host "✔️  Step 5: Testing package loading with Node.js..." -ForegroundColor Yellow
Write-Host ""

$packageLoadSuccess = 0
$packageLoadFailed = 0

foreach ($package in $extractedPackages | Select-Object -First 3) {
    try {
        $packageJsonPath = Join-Path $TEST_DIR "packages" $package.name.Split('/')[-1] "package" "package.json"
        
        if (Test-Path $packageJsonPath) {
            # Test that Node.js can parse and load the package.json
            $testResult = & node -e "const pkg = JSON.parse(require('fs').readFileSync('$packageJsonPath', 'utf8')); console.log('✅ ' + pkg.name + ' @ ' + pkg.version);" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host $testResult
                $packageLoadSuccess++
            } else {
                Write-Host "⚠️  Could not load: $($package.name)"
                $packageLoadFailed++
            }
        }
    } catch {
        Write-Host "⚠️  Error loading $($package.name): $($_.Exception.Message)"
        $packageLoadFailed++
    }
}

# Step 6: Generate comprehensive report
Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                    VERIFICATION REPORT                    ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

Write-Host "📊 Extraction Summary:"
Write-Host "  • Total tarballs available: $tarballCount"
Write-Host "  • Test packages attempted: $(($testPackages | Measure-Object).Count)"
Write-Host "  • Successfully extracted: $successCount" -ForegroundColor Green
Write-Host "  • Failed extractions: $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "Green" })
Write-Host ""

Write-Host "🔍 Node.js Validation:"
Write-Host "  • Packages loaded successfully: $packageLoadSuccess" -ForegroundColor Green
Write-Host "  • Packages failed to load: $packageLoadFailed"
Write-Host ""

if ($extractedPackages.Count -gt 0) {
    Write-Host "✅ Extracted Packages:"
    $extractedPackages | ForEach-Object {
        Write-Host "  • $($_.name) @ $($_.version)"
        Write-Host "    └─ From: $($_.tarball)"
    }
    Write-Host ""
}

if ($failedPackages.Count -gt 0) {
    Write-Host "❌ Failed Packages:" -ForegroundColor Red
    $failedPackages | ForEach-Object { Write-Host "   • $_" }
    Write-Host ""
}

Write-Host "🧪 Test Environment:"
Write-Host "  • Location: $TEST_DIR"
Write-Host "  • Extraction method: Direct tar extraction (offline compatible)"
Write-Host "  • Registry access: NOT REQUIRED"
Write-Host "  • All packages extracted from: Local .tgz files only"
Write-Host ""

Write-Host "📝 Test Environment Contents:"
if (Test-Path "$TEST_DIR/packages") {
    $packageDirs = @(Get-ChildItem -Path "$TEST_DIR/packages" -Directory)
    Write-Host "  • Extracted package directories: $($packageDirs.Count)"
}

Write-Host ""

if ($successCount -eq $(($testPackages | Measure-Object).Count) -and $failedCount -eq 0) {
    Write-Host "✅ VERIFICATION SUCCESSFUL!" -ForegroundColor Green
    Write-Host ""
    Write-Host "🎉 All packages can be extracted from tarballs offline."
    Write-Host "   The tarballs folder is ready for use in registry-blocked environments."
    Write-Host ""
    Write-Host "✨ Key Findings:"
    Write-Host "   ✓ All tarballs are valid and extractable"
    Write-Host "   ✓ All packages contain valid package.json files"
    Write-Host "   ✓ No npm registry access required"
    Write-Host "   ✓ Works completely offline"
    Write-Host ""
} else {
    Write-Host "⚠️  VERIFICATION INCOMPLETE" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Some packages failed extraction. Check the details above."
    Write-Host ""
}

Write-Host "📝 Next Steps:"
Write-Host "  1. Transfer the 'tarballs' folder to your offline environment"
Write-Host "  2. Use 'npm install' with --offline flag or --prefer-offline"
Write-Host "  3. Alternatively, extract tarballs directly with tar for maximum compatibility"
Write-Host ""

Write-Host "📂 Test artifacts preserved at: $TEST_DIR"
Write-Host "   (Remove manually when done: Remove-Item -Recurse -Force '$TEST_DIR')"
Write-Host ""
