#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
violations_file="$(mktemp)"
trap 'rm -f "$violations_file"' EXIT

normalize_dep_name() {
  local dep_name="$1"
  dep_name="${dep_name%%[<>=]*}"
  dep_name="${dep_name%%:*}"
  dep_name="${dep_name//[[:space:]]/}"
  [[ -z "$dep_name" ]] && return 1
  printf '%s\n' "$dep_name"
}

while IFS= read -r srcinfo_file; do
  while IFS= read -r dep_name; do
    case "$dep_name" in
      bun|nodejs|nodejs-*|npm|pnpm|yarn)
        printf '%s: banned dependency: %s\n' "$srcinfo_file" "$dep_name" >> "$violations_file"
        ;;
    esac
  done < <(
    awk -F' = ' '
      {
        field = $1
        sub(/^[[:space:]]*/, "", field)
        if (field == "depends" || field == "makedepends" || field == "checkdepends" ||
            field ~ /^depends_/ || field ~ /^makedepends_/ || field ~ /^checkdepends_/) {
          print $2
        }
      }
    ' "$srcinfo_file" | while IFS= read -r value; do
      normalize_dep_name "$value" || true
    done
  )
done < <(find "$repo_root/packages" -mindepth 2 -maxdepth 2 -type f -name .SRCINFO | sort)

while IFS= read -r package_file; do
  if [[ "$(basename "$package_file")" == ".SRCINFO" ]]; then
    continue
  fi
  grep -EniH \
    '(^|[;&|[:space:]])(bun|npm|pnpm|yarn|npx)([[:space:]]+(install|ci|add|exec|run|x|dlx|create|i)([^[:alnum:]_-]|$)|[[:space:]]*$)|(^|[;&|[:space:]])node[[:space:]]+|/usr/bin/node' \
    "$package_file" >> "$violations_file" || true
done < <(
  find "$repo_root/packages" -mindepth 2 -maxdepth 2 -type f \
    \( -name PKGBUILD -o -name '*.install' -o -name '*.hook' -o -name '*.sh' -o -name '*.py' \) \
    | sort
)

if [[ -s "$violations_file" ]]; then
  echo "Vendored package validation failed:" >&2
  cat "$violations_file" >&2
  exit 1
fi

echo "vendored package validation ok"
