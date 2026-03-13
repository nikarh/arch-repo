#!/usr/bin/env bash
set -euo pipefail

out_root="${1:-./.tmp/test-build}"
rm -rf "$out_root"
mkdir -p "$out_root"

scripts/build-packages.sh x86_64 "$out_root/x86_64"

echo "Built packages:"
find "$out_root/x86_64" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sed 's#^# - #' 

echo "Manifest:"
cat "$out_root/x86_64/manifest.json"
