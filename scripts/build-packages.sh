#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <arch> <out_dir> [package_filter]" >&2
  exit 1
fi

arch="$1"
out_dir="$(realpath -m "$2")"
package_filter="${3:-${PACKAGE_FILTER:-}}"
config_file="${PACKAGES_CONFIG_FILE:-packages.json}"
makepkg_runner="${MAKEPKG_DOCKER_BIN:-$PWD/scripts/makepkg-docker.sh}"

if [[ ! -f "$config_file" ]]; then
  echo "missing $config_file" >&2
  exit 1
fi

mkdir -p "$out_dir"
shared_artifact_dir="$out_dir"
work_root="$(mktemp -d)"
manifest_tmp="$work_root/manifest.ndjson"
release_assets_file="$work_root/release-assets.txt"
selected_ids_file="$work_root/selected-ids.json"
selected_ids_with_deps_file="$work_root/selected-ids-with-deps.json"
arch_packages_all_file="$work_root/packages-all.ndjson"
arch_packages_file="$work_root/packages.ndjson"
package_metadata_file="$work_root/package-metadata.ndjson"
trap 'rm -rf "$work_root"' EXIT
retry_count="${BUILD_RETRY_COUNT:-3}"
retry_delay_sec="${BUILD_RETRY_DELAY_SEC:-20}"
repo_name=$(jq -r '.repo.name // "arc-poc"' "$config_file")
github_repository="${GITHUB_REPOSITORY:-}"

if [[ -z "$github_repository" ]] && git_remote_url="$(git remote get-url origin 2>/dev/null)"; then
  if [[ "$git_remote_url" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
    github_repository="${BASH_REMATCH[1]}"
  fi
fi

prebuilt_repo_url=""
if [[ -n "$github_repository" ]]; then
  prebuilt_repo_url="https://github.com/${github_repository}/releases/download/repo-${arch}"
fi

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

normalize_dep_name() {
  local dep_name="$1"
  dep_name="${dep_name%%[<>=]*}"
  dep_name="${dep_name%%:*}"
  dep_name="${dep_name//[[:space:]]/}"
  [[ -z "$dep_name" ]] && return 1
  [[ "$dep_name" == *".so"* || "$dep_name" == */* ]] && return 1
  printf '%s\n' "$dep_name"
}

srcinfo_values() {
  local srcinfo_file="$1"
  local fields="$2"
  awk -F' = ' -v fields="$fields" '
    BEGIN {
      split(fields, names, ",")
      for (idx in names) {
        wanted[names[idx]] = 1
      }
    }
    {
      field = $1
      sub(/^[[:space:]]*/, "", field)
      if (field in wanted) {
        print $2
      }
    }
  ' "$srcinfo_file" | while IFS= read -r value; do
    normalize_dep_name "$value" || true
  done | sort -u
}

srcinfo_dep_values() {
  local srcinfo_file="$1"
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
  done | sort -u
}

json_array_from_file() {
  local values_file="$1"
  if [[ -s "$values_file" ]]; then
    jq -R . "$values_file" | jq -s .
  else
    echo '[]'
  fi
}

write_package_metadata() {
  local pkg pkg_id local_path srcinfo_file
  local pkgnames_file provides_file deps_file
  : > "$package_metadata_file"

  while IFS= read -r pkg; do
    pkg_id=$(jq -r '.id // empty' <<<"$pkg")
    local_path=$(jq -r --arg pkg_id "$pkg_id" '.path // ("packages/" + $pkg_id)' <<<"$pkg")
    srcinfo_file="$local_path/.SRCINFO"
    if [[ ! -f "$srcinfo_file" ]]; then
      srcinfo_file="$local_path/.codex-srcinfo"
    fi

    pkgnames_file="$work_root/${pkg_id}.pkgnames"
    provides_file="$work_root/${pkg_id}.provides"
    deps_file="$work_root/${pkg_id}.deps"

    if [[ -f "$srcinfo_file" ]]; then
      srcinfo_values "$srcinfo_file" "pkgname" > "$pkgnames_file"
      srcinfo_values "$srcinfo_file" "provides" > "$provides_file"
      srcinfo_dep_values "$srcinfo_file" > "$deps_file"
    else
      printf '%s\n' "$pkg_id" > "$pkgnames_file"
      : > "$provides_file"
      : > "$deps_file"
    fi

    if [[ ! -s "$pkgnames_file" ]]; then
      printf '%s\n' "$pkg_id" > "$pkgnames_file"
    fi

    jq -nc \
      --arg id "$pkg_id" \
      --argjson pkgnames "$(json_array_from_file "$pkgnames_file")" \
      --argjson provides "$(json_array_from_file "$provides_file")" \
      --argjson deps "$(json_array_from_file "$deps_file")" \
      '{id:$id, pkgnames:$pkgnames, provides:$provides, deps:$deps}' >> "$package_metadata_file"
  done < "$arch_packages_all_file"
}

expand_selected_packages() {
  cp "$selected_ids_file" "$selected_ids_with_deps_file"

  if [[ "$(jq 'length' "$selected_ids_with_deps_file")" -eq 0 ]]; then
    return 0
  fi

  local deps_file deps_json_file new_ids_file new_ids_json_file merged_file
  while true; do
    deps_file="$work_root/filter-deps.txt"
    deps_json_file="$work_root/filter-deps.json"
    new_ids_file="$work_root/filter-new-ids.txt"
    new_ids_json_file="$work_root/filter-new-ids.json"
    merged_file="$work_root/filter-merged.json"

    jq -r --slurpfile selected "$selected_ids_with_deps_file" '
      ($selected[0] // []) as $selected
      | .id as $id
      | select($selected | index($id))
      | .deps[]?
    ' "$package_metadata_file" | sort -u > "$deps_file"
    json_array_from_file "$deps_file" > "$deps_json_file"

    jq -r \
      --slurpfile selected "$selected_ids_with_deps_file" \
      --slurpfile deps "$deps_json_file" \
      '
      ($selected[0] // []) as $selected
      | ($deps[0] // []) as $deps
      | .id as $id
      | select(($selected | index($id) | not) and (((.pkgnames + .provides) | map(select($deps | index(.))) | length) > 0))
      | .id
      ' "$package_metadata_file" | sort -u > "$new_ids_file"

    if [[ ! -s "$new_ids_file" ]]; then
      break
    fi

    json_array_from_file "$new_ids_file" > "$new_ids_json_file"
    jq -s '.[0] + .[1] | unique' "$selected_ids_with_deps_file" "$new_ids_json_file" > "$merged_file"
    mv "$merged_file" "$selected_ids_with_deps_file"
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

jq -c \
  --arg arch "$arch" \
  '
  def package_entry:
    if type == "string" then
      {id:.}
    elif type == "object" then
      .
    else
      error("package entries must be strings or objects")
    end;

  . as $root
  | ($root.repo.default_arches // ["x86_64","aarch64"]) as $default_arches
  | $root.packages[]
  | package_entry
  | if (.id // "") == "" then error("package entry is missing id") else . end
  | select((.arches // $default_arches) | index($arch))
  ' "$config_file" > "$arch_packages_all_file"

write_package_metadata
expand_selected_packages

jq -c \
  --slurpfile selected_ids "$selected_ids_with_deps_file" \
  '
  ($selected_ids[0] // []) as $selected
  | .id as $id
  | select(($selected | length) == 0 or ($selected | index($id)))
  ' "$arch_packages_all_file" > "$arch_packages_file"

count=$(wc -l < "$arch_packages_file")
if [[ "$count" -eq 0 ]]; then
  if [[ -n "$package_filter" ]]; then
    echo "No packages configured for arch=$arch matching package_filter=$package_filter"
  else
    echo "No packages configured for arch=$arch"
  fi
fi

while IFS= read -r pkg; do
  pkg_id=$(jq -r '.id // empty' <<<"$pkg")
  if [[ -z "$pkg_id" ]]; then
    echo "package entry is missing id, cannot derive package identifier" >&2
    exit 1
  fi
  pkg_work="$work_root/$pkg_id"
  src_dir="$pkg_work/src"
  pkg_out="$pkg_work/out"
  mkdir -p "$src_dir" "$pkg_out"

  pkg_skip_existing=$(jq -r --argjson def "$global_skip_existing" 'if has("prebuild_skip_existing_version") then .prebuild_skip_existing_version else $def end' <<<"$pkg")
  pkg_same_policy=$(jq -r '.same_version_rebuild_policy // empty' <<<"$pkg")
  pkg_cleanup_old_versions=$(jq -r '.cleanup_old_versions // false' <<<"$pkg")
  pkg_extra_build_deps=$(jq -r '(.extra_build_deps // []) | join(" ")' <<<"$pkg")
  pkg_build_auto_debug=$(jq -r --argjson def "$global_build_auto_debug" 'if has("build_auto_debug_packages") then .build_auto_debug_packages else $def end' <<<"$pkg")
  if [[ -z "$pkg_same_policy" ]]; then
    pkg_same_policy="$global_same_policy"
  fi
  if [[ "$pkg_same_policy" != "warn_skip_upload" && "$pkg_same_policy" != "force_upload" ]]; then
    echo "invalid same_version_rebuild_policy for $pkg_id: $pkg_same_policy" >&2
    exit 1
  fi

  echo "==> processing $pkg_id for $arch"

  local_path=$(jq -r --arg pkg_id "$pkg_id" '.path // ("packages/" + $pkg_id)' <<<"$pkg")
  if [[ ! -d "$local_path" ]]; then
    echo "missing local package source for $pkg_id: $local_path" >&2
    exit 1
  fi
  cp -a "$local_path"/. "$src_dir"/

  list_err="$pkg_work/list.err"
  if ! EXTRA_BUILD_DEPS="$pkg_extra_build_deps" BUILD_AUTO_DEBUG_PACKAGES="$pkg_build_auto_debug" MAKEPKG_SHARED_ARTIFACT_DIR="$shared_artifact_dir" PREBUILT_REPO_NAME="$repo_name" PREBUILT_REPO_URL="$prebuilt_repo_url" "$makepkg_runner" "$arch" "$src_dir" "$pkg_out" list >"$pkg_work/list.out" 2>"$list_err"; then
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

  retry_cmd "build package $pkg_id for $arch" env EXTRA_BUILD_DEPS="$pkg_extra_build_deps" BUILD_AUTO_DEBUG_PACKAGES="$pkg_build_auto_debug" MAKEPKG_SHARED_ARTIFACT_DIR="$shared_artifact_dir" PREBUILT_REPO_NAME="$repo_name" PREBUILT_REPO_URL="$prebuilt_repo_url" "$makepkg_runner" "$arch" "$src_dir" "$pkg_out" build

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
    printf '%s\n' "$filename" >> "$release_assets_file"
    if [[ -f "$pkgfile.sig" ]]; then
      cp "$pkgfile.sig" "$out_dir/$filename.sig"
      printf '%s\n' "$filename.sig" >> "$release_assets_file"
    fi

    pkgname="${BASH_REMATCH[1]}"
    pkgver="${BASH_REMATCH[2]}"
    pkgrel="${BASH_REMATCH[3]}"
    pkgarch="${BASH_REMATCH[4]}"
    sha256_line="$(sha256sum "$pkgfile")"
    sha256="${sha256_line%% *}"

    jq -nc \
      --arg id "$pkg_id" \
      --arg pkgname "$pkgname" \
      --arg version "$pkgver-$pkgrel" \
      --arg arch "$pkgarch" \
      --arg filename "$filename" \
      --arg sha256 "$sha256" \
      --arg same_version_rebuild_policy "$pkg_same_policy" \
      --argjson cleanup_old_versions "$pkg_cleanup_old_versions" \
      '{id:$id, pkgname:$pkgname, version:$version, arch:$arch, filename:$filename, sha256:$sha256, same_version_rebuild_policy:$same_version_rebuild_policy, cleanup_old_versions:$cleanup_old_versions}' >> "$manifest_tmp"
  done
  sort -u -o "$release_assets_file" "$release_assets_file"
done < "$arch_packages_file"

if [[ -f "$manifest_tmp" ]]; then
  jq -s '.' "$manifest_tmp" > "$out_dir/manifest.json"
else
  echo '[]' > "$out_dir/manifest.json"
fi

echo "Wrote manifest to $out_dir/manifest.json"
