#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <arch> <out_dir> [package_filter]" >&2
  exit 1
fi

arch="$1"
out_dir="$(realpath -m "$2")"
package_filter="${3:-${PACKAGE_FILTER:-}}"
config_file="packages.json"

if [[ ! -f "$config_file" ]]; then
  echo "missing $config_file" >&2
  exit 1
fi

mkdir -p "$out_dir"
work_root="$(mktemp -d)"
manifest_tmp="$work_root/manifest.ndjson"
release_assets_file="$work_root/release-assets.txt"
selected_ids_file="$work_root/selected-ids.json"
trap 'rm -rf "$work_root"' EXIT
retry_count="${BUILD_RETRY_COUNT:-3}"
retry_delay_sec="${BUILD_RETRY_DELAY_SEC:-20}"

if [[ -n "$package_filter" ]]; then
  printf '%s' "$package_filter" \
    | tr ',\n' '\n\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d' \
    | sort -u \
    | jq -R . \
    | jq -s . > "$selected_ids_file"
else
  echo '[]' > "$selected_ids_file"
fi

if ! [[ "$retry_count" =~ ^[0-9]+$ ]] || (( retry_count < 1 )); then
  echo "BUILD_RETRY_COUNT must be an integer >= 1" >&2
  exit 1
fi
if ! [[ "$retry_delay_sec" =~ ^[0-9]+$ ]] || (( retry_delay_sec < 0 )); then
  echo "BUILD_RETRY_DELAY_SEC must be an integer >= 0" >&2
  exit 1
fi

retry_cmd() {
  local label="$1"
  shift
  local attempt=1
  local rc=0
  while true; do
    if "$@"; then
      return 0
    fi
    rc=$?
    if (( attempt >= retry_count )); then
      echo "ERROR: $label failed after ${retry_count} attempts" >&2
      return "$rc"
    fi
    echo "WARN: $label failed (attempt ${attempt}/${retry_count}); retrying in ${retry_delay_sec}s" >&2
    sleep "$retry_delay_sec"
    attempt=$((attempt + 1))
  done
}

global_skip_existing=$(jq -r '.repo.prebuild_skip_existing_version // true' "$config_file")
global_same_policy=$(jq -r '.repo.same_version_rebuild_policy // "warn_skip_upload"' "$config_file")
global_build_auto_debug=$(jq -r '.repo.build_auto_debug_packages // false' "$config_file")

if [[ "$global_same_policy" != "warn_skip_upload" ]]; then
  echo "repo.same_version_rebuild_policy only supports warn_skip_upload globally" >&2
  exit 1
fi

: > "$release_assets_file"
api_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -n "${GITHUB_REPOSITORY:-}" && -n "$api_token" ]]; then
  rel_json="$work_root/release.json"
  rel_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/repo-${arch}"
  if curl -fsSL \
    -H "Authorization: Bearer ${api_token}" \
    -H "Accept: application/vnd.github+json" \
    "$rel_url" > "$rel_json" 2>/dev/null; then
    jq -r '.assets[]?.name' "$rel_json" > "$release_assets_file"
    echo "Loaded $(wc -l < "$release_assets_file") release assets from repo-${arch}"
  else
    echo "No existing release assets found for repo-${arch}; all packages will build"
  fi
else
  echo "Missing GITHUB_REPOSITORY or token; release-aware prebuild skipping disabled"
fi

count=$(jq \
  --arg arch "$arch" \
  --slurpfile selected_ids "$selected_ids_file" \
  '
  . as $root
  | ($root.repo.default_arches // ["x86_64","aarch64"]) as $default_arches
  | ($selected_ids[0] // []) as $selected
  |
  [
    $root.packages[]
    | select((.arches // $default_arches) | index($arch))
    | select(($selected | length) == 0 or ($selected | index(.id)))
  ] | length
  ' "$config_file")
if [[ "$count" -eq 0 ]]; then
  if [[ -n "$package_filter" ]]; then
    echo "No packages configured for arch=$arch matching package_filter=$package_filter"
  else
    echo "No packages configured for arch=$arch"
  fi
fi

jq -c \
  --arg arch "$arch" \
  --slurpfile selected_ids "$selected_ids_file" \
  '
  . as $root
  | ($root.repo.default_arches // ["x86_64","aarch64"]) as $default_arches
  | ($selected_ids[0] // []) as $selected
  | $root.packages[]
  | select((.arches // $default_arches) | index($arch))
  | select(($selected | length) == 0 or ($selected | index(.id)))
  ' "$config_file" | \
while IFS= read -r pkg; do
  pkg_id=$(jq -r '.id // empty' <<<"$pkg")
  if [[ -z "$pkg_id" ]]; then
    echo "package entry is missing id, cannot derive package identifier" >&2
    exit 1
  fi
  pkg_type=$(jq -r '.type' <<<"$pkg")
  pkg_work="$work_root/$pkg_id"
  src_dir="$pkg_work/src"
  pkg_out="$pkg_work/out"
  mkdir -p "$src_dir" "$pkg_out"

  pkg_skip_existing=$(jq -r --argjson def "$global_skip_existing" '.prebuild_skip_existing_version // $def' <<<"$pkg")
  pkg_same_policy=$(jq -r '.same_version_rebuild_policy // empty' <<<"$pkg")
  pkg_extra_build_deps=$(jq -r '(.extra_build_deps // []) | join(" ")' <<<"$pkg")
  pkg_build_auto_debug=$(jq -r --argjson def "$global_build_auto_debug" '.build_auto_debug_packages // $def' <<<"$pkg")
  if [[ -z "$pkg_same_policy" ]]; then
    pkg_same_policy="$global_same_policy"
  fi
  if [[ "$pkg_same_policy" != "warn_skip_upload" && "$pkg_same_policy" != "force_upload" ]]; then
    echo "invalid same_version_rebuild_policy for $pkg_id: $pkg_same_policy" >&2
    exit 1
  fi

  echo "==> processing $pkg_id ($pkg_type) for $arch"

  case "$pkg_type" in
    aur)
      clone_aur() {
        rm -rf "$src_dir"
        git clone --depth=1 "https://aur.archlinux.org/${pkg_id}.git" "$src_dir"
      }
      retry_cmd "clone AUR package $pkg_id" clone_aur
      ;;
    local)
      local_path=$(jq -r --arg pkg_id "$pkg_id" '.path // ("packages/" + $pkg_id)' <<<"$pkg")
      cp -a "$local_path"/. "$src_dir"/
      ;;
    *)
      echo "unsupported package type for $pkg_id: $pkg_type" >&2
      exit 1
      ;;
  esac

  list_err="$pkg_work/list.err"
  if ! EXTRA_BUILD_DEPS="$pkg_extra_build_deps" BUILD_AUTO_DEBUG_PACKAGES="$pkg_build_auto_debug" "$PWD/scripts/makepkg-docker.sh" "$arch" "$src_dir" "$pkg_out" list >"$pkg_work/list.out" 2>"$list_err"; then
    if grep -q "not available for the '${arch}' architecture" "$list_err"; then
      echo "SKIP BUILD: $pkg_id not available for arch=$arch"
      continue
    fi
    cat "$list_err" >&2
    echo "failed to resolve expected package files for $pkg_id" >&2
    exit 1
  fi
  mapfile -t expected_files < <(sort -u "$pkg_work/list.out")

  should_build=1
  if [[ "$pkg_skip_existing" == "true" && -s "$release_assets_file" && ${#expected_files[@]} -gt 0 ]]; then
    all_found=1
    for expected in "${expected_files[@]}"; do
      [[ -z "$expected" ]] && continue
      if ! grep -Fxq "$expected" "$release_assets_file"; then
        all_found=0
        break
      fi
    done
    if [[ "$all_found" -eq 1 ]]; then
      should_build=0
      echo "SKIP BUILD: $pkg_id already has version assets in repo-${arch}"
    fi
  fi

  if [[ "$should_build" -eq 0 ]]; then
    continue
  fi

  retry_cmd "build package $pkg_id for $arch" env EXTRA_BUILD_DEPS="$pkg_extra_build_deps" BUILD_AUTO_DEBUG_PACKAGES="$pkg_build_auto_debug" "$PWD/scripts/makepkg-docker.sh" "$arch" "$src_dir" "$pkg_out" build

  shopt -s nullglob
  pkg_files=("$pkg_out"/*.pkg.tar.*)
  if [[ ${#pkg_files[@]} -eq 0 ]]; then
    echo "no package files produced for $pkg_id" >&2
    exit 1
  fi

  for pkgfile in "${pkg_files[@]}"; do
    [[ "$pkgfile" == *.sig ]] && continue

    filename=$(basename "$pkgfile")
    if [[ ! "$filename" =~ ^(.+)-([^-]+)-([^-]+)-([^-]+)\.pkg\.tar\..+$ ]]; then
      echo "unable to parse package filename: $filename" >&2
      exit 1
    fi

    cp "$pkgfile" "$out_dir/$filename"
    if [[ -f "$pkgfile.sig" ]]; then
      cp "$pkgfile.sig" "$out_dir/$filename.sig"
    fi

    pkgname="${BASH_REMATCH[1]}"
    pkgver="${BASH_REMATCH[2]}"
    pkgrel="${BASH_REMATCH[3]}"
    pkgarch="${BASH_REMATCH[4]}"
    sha256_line="$(sha256sum "$pkgfile")"
    sha256="${sha256_line%% *}"

    jq -nc \
      --arg pkg_id "$pkg_id" \
      --arg pkgname "$pkgname" \
      --arg version "$pkgver-$pkgrel" \
      --arg arch "$pkgarch" \
      --arg filename "$filename" \
      --arg sha256 "$sha256" \
      --arg same_version_rebuild_policy "$pkg_same_policy" \
      '{pkg_id:$pkg_id, pkgname:$pkgname, version:$version, arch:$arch, filename:$filename, sha256:$sha256, same_version_rebuild_policy:$same_version_rebuild_policy}' >> "$manifest_tmp"
  done
done

if [[ -f "$manifest_tmp" ]]; then
  jq -s '.' "$manifest_tmp" > "$out_dir/manifest.json"
else
  echo '[]' > "$out_dir/manifest.json"
fi

echo "Wrote manifest to $out_dir/manifest.json"
