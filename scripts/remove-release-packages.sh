#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <package_names>" >&2
  exit 1
fi

package_input="$1"
config_file="packages.json"

if [[ ! -f "$config_file" ]]; then
  echo "missing $config_file" >&2
  exit 1
fi
if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
  echo "GITHUB_REPOSITORY is required" >&2
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

repo_name=$(jq -r '.repo.name // "arc-poc"' "$config_file")

mapfile -t package_names < <(
  printf '%s' "$package_input" \
    | tr ',\n' '\n\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d' \
    | sort -u
)

if [[ ${#package_names[@]} -eq 0 ]]; then
  echo "no package names were provided" >&2
  exit 1
fi

declare -A requested_packages=()
for pkg in "${package_names[@]}"; do
  requested_packages["$pkg"]=1
done

requested_packages_json="$(
  printf '%s\n' "${package_names[@]}" | jq -R . | jq -s .
)"

mapfile -t release_tags < <(
  (
    gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" --jq '.[].tag_name' \
      | grep '^repo-' \
      | sort -u
  ) || true
)

if [[ ${#release_tags[@]} -eq 0 ]]; then
  echo "no repo-* releases found in ${GITHUB_REPOSITORY}"
  exit 0
fi

parse_pkgname_from_asset() {
  local asset_name="$1"
  local base_name="$asset_name"
  if [[ "$base_name" == *.sig ]]; then
    base_name="${base_name%.sig}"
  fi

  if [[ ! "$base_name" =~ ^(.+)-([^-]+)-([^-]+)-([^-]+)\.pkg\.tar\..+$ ]]; then
    return 1
  fi

  printf '%s\n' "${BASH_REMATCH[1]}"
}

delete_asset_ids=() # kept global for shellcheck-friendly reuse in loops

for release_tag in "${release_tags[@]}"; do
  echo "==> processing ${release_tag}"

  tmp_root="$(mktemp -d)"
  release_json="$tmp_root/release.json"
  repo_dir="$tmp_root/repo"
  mkdir -p "$repo_dir"
  trap 'rm -rf "$tmp_root"' EXIT

  gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${release_tag}" > "$release_json"

  mapfile -t assets < <(jq -r '.assets[] | @base64' "$release_json")

  delete_asset_ids=()
  delete_asset_names=()
  current_state_targets=()
  release_matches=0

  state_file="$tmp_root/state.json"
  if ! gh release download "$release_tag" --pattern 'state.json' --dir "$tmp_root" >/dev/null 2>&1; then
    echo '{"packages":{}}' > "$state_file"
  fi
  if ! jq -e '.packages' "$state_file" >/dev/null 2>&1; then
    echo '{"packages":{}}' > "$state_file"
  fi

  for pkg in "${package_names[@]}"; do
    if jq -e --arg pkg "$pkg" '.packages[$pkg]' "$state_file" >/dev/null; then
      current_state_targets+=("$pkg")
      release_matches=1
    fi
  done

  for asset_b64 in "${assets[@]}"; do
    asset_json="$(printf '%s' "$asset_b64" | base64 -d)"
    asset_id="$(jq -r '.id' <<<"$asset_json")"
    asset_name="$(jq -r '.name' <<<"$asset_json")"

    if ! pkgname="$(parse_pkgname_from_asset "$asset_name")"; then
      continue
    fi

    if [[ -n "${requested_packages[$pkgname]:-}" ]]; then
      delete_asset_ids+=("$asset_id")
      delete_asset_names+=("$asset_name")
      release_matches=1
    fi
  done

  if [[ "$release_matches" -eq 0 ]]; then
    echo "No matching packages found in ${release_tag}; skipping"
    rm -rf "$tmp_root"
    trap - EXIT
    continue
  fi

  updated_state="$tmp_root/state.updated.json"
  jq --argjson remove "$requested_packages_json" '
    .packages |= with_entries(select(.key as $key | ($remove | index($key) | not)))
  ' "$state_file" > "$updated_state"
  mv "$updated_state" "$state_file"

  metadata_changed=0
  if [[ ${#current_state_targets[@]} -gt 0 ]]; then
    gh release download "$release_tag" --pattern "${repo_name}.db.tar.gz" --pattern "${repo_name}.files.tar.gz" --dir "$repo_dir" >/dev/null

    docker run --rm \
      -v "$repo_dir:/repo" \
      archlinux:base-devel \
      repo-remove "/repo/${repo_name}.db.tar.gz" "${current_state_targets[@]}"

    ln -sf "${repo_name}.db.tar.gz" "$repo_dir/${repo_name}.db"
    ln -sf "${repo_name}.files.tar.gz" "$repo_dir/${repo_name}.files"
    metadata_changed=1
  fi

  upload_list=("$state_file")
  if [[ "$metadata_changed" -eq 1 ]]; then
    upload_list+=(
      "$repo_dir/${repo_name}.db.tar.gz"
      "$repo_dir/${repo_name}.db"
      "$repo_dir/${repo_name}.files.tar.gz"
      "$repo_dir/${repo_name}.files"
    )
  fi

  if [[ "$metadata_changed" -eq 1 && -n "${GPG_PRIVATE_KEY_B64:-}" && -n "${GPG_KEY_ID:-}" ]]; then
    gpg_home="$tmp_root/gnupg"
    mkdir -p "$gpg_home"
    chmod 700 "$gpg_home"
    export GNUPGHOME="$gpg_home"

    echo "$GPG_PRIVATE_KEY_B64" | base64 -d | gpg --batch --import

    sign_targets=(
      "$repo_dir/${repo_name}.db.tar.gz"
      "$repo_dir/${repo_name}.db"
      "$repo_dir/${repo_name}.files.tar.gz"
      "$repo_dir/${repo_name}.files"
    )

    for target in "${sign_targets[@]}"; do
      gpg --batch --yes --pinentry-mode loopback \
        --passphrase "${GPG_PASSPHRASE:-}" \
        --local-user "$GPG_KEY_ID" \
        --detach-sign --armor "$target"
      upload_list+=("$target.asc")
    done
  fi

  if [[ ${#delete_asset_ids[@]} -gt 0 ]]; then
    for idx in "${!delete_asset_ids[@]}"; do
      echo "Deleting asset ${delete_asset_names[$idx]}"
      gh api \
        --method DELETE \
        "repos/${GITHUB_REPOSITORY}/releases/assets/${delete_asset_ids[$idx]}" \
        >/dev/null
    done
  fi

  gh release upload "$release_tag" --clobber "${upload_list[@]}"
  echo "Updated ${release_tag}"

  rm -rf "$tmp_root"
  trap - EXIT
done
