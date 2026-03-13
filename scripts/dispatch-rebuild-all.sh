#!/usr/bin/env bash
set -euo pipefail

repo="${1:-nikarh/arch-repo}"
trigger_final_publish="${TRIGGER_FINAL_PUBLISH:-1}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required" >&2
  exit 1
fi

mapfile -t packages < <(jq -r '.packages[].id' packages.json | sort -u)
if [[ ${#packages[@]} -eq 0 ]]; then
  echo "No packages found in packages.json" >&2
  exit 1
fi

for pkg in "${packages[@]}"; do
  echo "Dispatching package=$pkg (publish=false)"
  gh workflow run build-and-release.yml -R "$repo" -f package="$pkg" -f publish=false
  sleep 1
done

if [[ "$trigger_final_publish" == "1" ]]; then
  echo "Dispatching final publish run (full config, publish=true)"
  gh workflow run build-and-release.yml -R "$repo" -f publish=true
fi

