#!/usr/bin/env bash
set -e

CACHE_DIR="‪C:\appzone\npm-offline\cache"   # change to network path or local dir

echo "Using npm cache: $CACHE_DIR"

npm config set cache "$CACHE_DIR"
npm config set prefer-offline true
npm config set fund false
npm config set audit false

echo "✅ npm configured for offline usage"
npm config list
