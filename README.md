# npm Offline Cache Manager

A utility to pre-download and cache npm packages for offline development environments or isolated networks.

## Overview

This project automates the process of creating a portable npm cache that can be used in environments without internet access or with network restrictions. It downloads all specified packages and their entire dependency trees, stores them locally, and provides tools to verify cache integrity.

## Features

- 📦 **Automated Package Prefetching** - Downloads packages and dependencies with a single script
- 🔍 **Cache Verification** - Validates that all cached packages are available for offline installation
- ⚙️ **Offline Configuration** - Easy setup script to configure npm for offline mode
- 🤖 **CI/CD Integration** - GitHub Actions workflow for automated cache generation and distribution
- 🖥️ **Cross-Platform** - Works on Windows, macOS, and Linux

## Project Structure

```
.
├── packages.txt              # List of packages to cache
├── prefetch.sh               # Downloads packages to cache
├── setup-work.sh             # Configures npm for offline usage
├── verify-cache.sh           # Verifies cache integrity
├── cache/                    # Local npm cache directory
│   └── _cacache/            # npm's internal cache format
└── .github/workflows/        # GitHub Actions automation
    └── prefetch.yml         # Automated cache generation workflow
```

## Quick Start

### 1. Configure Packages

Edit [packages.txt](packages.txt) to specify which packages to cache:

```txt
react@18.2.0
react-dom@18.2.0
axios
lodash
@mui/material
@emotion/react
@emotion/styled
```

You can specify:

- **Package name only** (e.g., `axios`) - Uses the latest version
- **Specific version** (e.g., `react@18.2.0`) - Uses that exact version

Lines starting with `#` are ignored (use for comments).

### 2. Prefetch Packages

Run the prefetch script to download all packages and their dependencies:

```bash
./prefetch.sh
```

This will:

- Create a `cache/` directory if it doesn't exist
- Resolve package versions (for packages without explicit versions)
- Download all packages and dependencies
- Display the total cache size

### 3. Verify Cache

Test that all packages are properly cached:

```bash
./verify-cache.sh
```

This performs dry-run offline installations to confirm all packages are available without network access.

### 4. Configure npm for Offline Usage

Set up npm to use the local cache:

```bash
./setup-work.sh
```

This configures:

- `npm_config_cache` - Points to the local cache directory
- `prefer-offline` - Uses cached versions when available
- Disables fund checks and audit notifications

### 5. Install Packages Offline

After configuration, install packages without internet:

```bash
npm install react react-dom axios
```

npm will use the pre-downloaded packages from the cache.

## Scripts Reference

### prefetch.sh

**Purpose:** Download packages and warm the npm cache

**What it does:**

1. Creates temporary npm project
2. Reads package list from `packages.txt`
3. Resolves latest versions for unspecified packages
4. Runs `npm install` to populate cache with all dependencies
5. Cleans up temporary files (preserves cache)

**Usage:**

```bash
./prefetch.sh
```

### setup-work.sh

**Purpose:** Configure npm to use the offline cache

**Configuration applied:**

- Sets cache directory to `./cache/`
- Enables prefer-offline mode
- Disables fund and audit warnings

**Usage:**

```bash
./setup-work.sh
```

**Note:** Update the `CACHE_DIR` variable in the script to point to your cache location if using a network path.

### verify-cache.sh

**Purpose:** Test offline package installation

**What it does:**

1. Creates temporary npm project
2. Attempts dry-run offline installs of each package
3. Reports missing packages if any
4. Cleans up temporary files

**Usage:**

```bash
./verify-cache.sh
```

## Using the Cache in Your Project

### Local Development

1. Run `./prefetch.sh` to generate cache
2. Run `./setup-work.sh` to configure npm
3. Run `npm install` in your project directory

### CI/CD Pipeline

Set the npm cache directory as an environment variable:

```bash
export npm_config_cache=/path/to/cache
npm install
```

Or use `.npmrc` file:

```
cache=/path/to/cache
prefer-offline=true
```

### Sharing the Cache

The GitHub Actions workflow automatically:

1. Generates the cache
2. Zips the `cache/` directory
3. Uploads to transfer.sh (temporary file sharing)
4. Provides a shareable download link

You can also manually zip and share:

```bash
zip -r offline-npm-cache.zip cache/
```

## Export Tarballs for Private Registries 🔁

If you need to push package tarballs (and their dependencies) to a private registry or artifact feed (for example, Azure DevOps Artifacts), use the included scripts to produce a set of .tgz files you can publish.

1. Generate tarballs for all packages listed in `packages.txt`:

```powershell
pwsh -NoProfile -File ./scripts/pull-tarballs.ps1
```

This will create a `tarballs/` directory containing unique package tarballs for each resolved dependency. The script works by creating a temporary project, generating a `package-lock.json`, extracting resolved tarball URLs, and downloading them. It also attempts `npm pack` as a fallback for edge cases.

2. (Optional) Publish tarballs to an Azure DevOps feed:

- Set `AZURE_REGISTRY` to your feed's registry URL (for example: `https://pkgs.dev.azure.com/ORG/_packaging/FEED/npm/registry/`)
- Optionally set `NPM_TOKEN` (or ensure `npm` is already authenticated)

There are two helper scripts:

- `scripts/publish-to-azure.sh`: publishes tarballs found in `./tarballs` (used by the CI helper before). Example:

```bash
chmod +x ./scripts/publish-to-azure.sh
AZURE_REGISTRY="https://pkgs.dev.azure.com/ORG/_packaging/FEED/npm/registry/" \
NPM_TOKEN="<token>" \
./scripts/publish-to-azure.sh
```

- `scripts/publish-folder-to-azure.sh`: new local helper to publish an extracted folder of `.tgz` files (useful on a work laptop). Example:

```bash
# publish all .tgz from the extracted folder (dry-run first)
chmod +x ./scripts/publish-folder-to-azure.sh
./scripts/publish-folder-to-azure.sh /path/to/extracted/tarballs --dry-run

# when ready:
AZURE_REGISTRY="https://pkgs.dev.azure.com/ORG/_packaging/FEED/npm/registry/" \
NPM_TOKEN="<token>" \
./scripts/publish-folder-to-azure.sh /path/to/extracted/tarballs
```

The script will create a temporary `.npmrc` if `NPM_TOKEN` is provided and will not persist credentials. It prints a short summary of successes and failures.

> Note: Ensure you have publish rights on the target feed and consult Azure DevOps docs for feed-specific auth details.

## GitHub Actions Workflow

The included workflow ([.github/workflows/prefetch.yml](.github/workflows/prefetch.yml)) automates cache generation:

**Trigger:** Manual dispatch via GitHub UI (`workflow_dispatch`)

**Steps:**

1. Check out repository
2. Install Node.js v20
3. Run prefetch script
4. Run verification script
5. Zip cache directory
6. Upload to transfer.sh
7. Display shareable link

To use:

1. Push this repo to GitHub
2. Go to **Actions** tab
3. Select **Prefetch and Upload NPM Cache (Windows)**
4. Click **Run workflow**
5. Wait for completion and download the link

### Pull tarballs workflow ✅

A separate workflow ([.github/workflows/pull-tarballs.yml](.github/workflows/pull-tarballs.yml)) is provided to:

- Run `pwsh -NoProfile -File ./scripts/pull-tarballs.ps1` on a Windows runner to produce a `tarballs/` directory of `.tgz` files for all packages and dependencies.
- Create a zipped artifact `offline-tarballs.zip` that contains all downloaded `.tgz` files and upload it as a workflow artifact named `offline-tarballs`.

To run it manually:

1. Go to **Actions** → **Pull and Upload Tarballs** → **Run workflow**
2. Download the `offline-tarballs` artifact from the workflow run (it will be a `.zip` you can extract locally to obtain the `.tgz` files)

> Note: The workflow does not automatically publish to private feeds. Use `scripts/publish-to-azure.sh` locally or in a separate pipeline if you want to upload the tarballs to an Azure DevOps feed (this action is not performed by the workflow by default).

This workflow runs on `windows-latest` and uses Git Bash to execute the scripts for Windows compatibility.

## Platform-Specific Notes

### Windows

If running Bash scripts on Windows, ensure you have Git Bash installed. The scripts are compatible with:

- Git Bash
- WSL (Windows Subsystem for Linux)
- Cygwin

### macOS/Linux

Scripts run directly in native Bash. Ensure execute permissions:

```bash
chmod +x prefetch.sh setup-work.sh verify-cache.sh
```

## Troubleshooting

### Cache Directory Not Found

**Issue:** `npm: command not found` or cache not being used

**Solution:**

- Verify the cache directory path in `setup-work.sh`
- Run `npm config list` to check current settings
- Ensure proper permissions on cache directory

### Missing Packages in Cache

**Issue:** `npm ERR! 404` when trying to install offline

**Solution:**

1. Add the package to `packages.txt`
2. Run `./prefetch.sh` again
3. Run `./verify-cache.sh` to confirm

### Offline Mode Not Working

**Issue:** npm still tries to access registry

**Solution:**

```bash
npm install --offline --prefer-offline
# or configure permanently
npm config set offline true
npm config set prefer-offline true
```

## Size Considerations

The cache size depends on the number of packages and their dependencies. Typical sizes:

- Basic packages (axios, lodash): ~50-100 MB
- React ecosystem: ~200-400 MB
- Large projects: 500+ MB

Monitor cache size:

```bash
du -sh cache/
```

## Contributing

To add or update packages:

1. Edit `packages.txt`
2. Run `./prefetch.sh`
3. Run `./verify-cache.sh`
4. Commit changes

## License

ISC

## Support

For issues or questions:

1. Check the troubleshooting section above
2. Review script output for error messages
3. Verify npm installation: `npm --version`
4. Check Node.js version compatibility
