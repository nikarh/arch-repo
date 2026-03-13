#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <arch> <artifact_dir>" >&2
  exit 1
fi

arch="$1"
artifact_dir="$(realpath "$2")"
config_file="packages.json"

if [[ ! -f "$config_file" ]]; then
  echo "missing $config_file" >&2
  exit 1
fi
if [[ ! -f "$artifact_dir/manifest.json" ]]; then
  echo "missing manifest: $artifact_dir/manifest.json" >&2
  exit 1
fi
if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
  echo "GITHUB_REPOSITORY is required" >&2
  exit 1
fi

repo_name=$(jq -r '.repo.name // "arc-poc"' "$config_file")
same_version_policy=$(jq -r '.repo.same_version_policy // "fail"' "$config_file")
release_tag="repo-${arch}"

tmp_root="$(mktemp -d)"
existing_dir="$tmp_root/existing"
combined_dir="$tmp_root/combined"
selected_dir="$tmp_root/selected"
state_file="$tmp_root/state.json"
prev_state="$tmp_root/prev_state.json"
mkdir -p "$existing_dir" "$combined_dir" "$selected_dir"
trap 'rm -rf "$tmp_root"' EXIT

if ! gh release view "$release_tag" >/dev/null 2>&1; then
  gh release create "$release_tag" \
    --title "Pacman repo ($arch)" \
    --notes "Auto-managed pacman repo assets for $arch."
fi

if gh release download "$release_tag" --pattern 'state.json' --dir "$tmp_root" >/dev/null 2>&1; then
  cp "$tmp_root/state.json" "$prev_state"
else
  echo '{"packages":{}}' > "$prev_state"
fi

if ! jq -e '.packages' "$prev_state" >/dev/null 2>&1; then
  echo '{"packages":{}}' > "$prev_state"
fi

gh release download "$release_tag" --pattern '*.pkg.tar.*' --dir "$existing_dir" >/dev/null 2>&1 || true
cp -a "$existing_dir"/. "$combined_dir"/ 2>/dev/null || true

mapfile -t new_pkgfiles < <(find "$artifact_dir" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' | sort)
if [[ ${#new_pkgfiles[@]} -eq 0 ]]; then
  echo "No package files to process for $arch"
fi

declare -a selected_files=()
cp "$prev_state" "$state_file"

for pkgpath in "${new_pkgfiles[@]}"; do
  filename="$(basename "$pkgpath")"
  info=$(jq -c --arg fn "$filename" '.[] | select(.filename==$fn)' "$artifact_dir/manifest.json")
  if [[ -z "$info" ]]; then
    echo "manifest entry missing for $filename" >&2
    exit 1
  fi

  pkgname=$(jq -r '.pkgname' <<<"$info")
  version=$(jq -r '.version' <<<"$info")
  sha256=$(jq -r '.sha256' <<<"$info")

  prev_entry=$(jq -c --arg pkg "$pkgname" '.packages[$pkg] // empty' "$prev_state")
  select_pkg=1

  if [[ -n "$prev_entry" ]]; then
    prev_version=$(jq -r '.version' <<<"$prev_entry")
    prev_sha256=$(jq -r '.sha256' <<<"$prev_entry")

    if [[ "$version" == "$prev_version" ]]; then
      if [[ "$sha256" == "$prev_sha256" ]]; then
        select_pkg=0
        echo "SKIP: $pkgname $version unchanged"
      else
        msg="same version but different content for $pkgname ($version)"
        if [[ "$same_version_policy" == "fail" ]]; then
          echo "ERROR: $msg" >&2
          exit 1
        fi
        echo "WARNING: $msg"
      fi
    fi
  fi

  if [[ "$select_pkg" -eq 1 ]]; then
    cp "$pkgpath" "$combined_dir/$filename"
    cp "$pkgpath" "$selected_dir/$filename"
    if [[ -f "$pkgpath.sig" ]]; then
      cp "$pkgpath.sig" "$combined_dir/$filename.sig"
      cp "$pkgpath.sig" "$selected_dir/$filename.sig"
      selected_files+=("$filename.sig")
    fi

    selected_files+=("$filename")
    state_file_tmp="$tmp_root/state.tmp.json"
    jq --arg pkg "$pkgname" \
      --arg version "$version" \
      --arg sha256 "$sha256" \
      --arg filename "$filename" \
      '.packages[$pkg] = {version:$version, sha256:$sha256, filename:$filename}' \
      "$state_file" > "$state_file_tmp"
    mv "$state_file_tmp" "$state_file"
  fi
done

repo_script=$(cat <<'EOS'
set -euo pipefail
repo_dir=/repo
repo_name="$REPO_NAME"

shopt -s nullglob
pkg_files=("$repo_dir"/*.pkg.tar.*)
real_pkg_files=()
for f in "${pkg_files[@]}"; do
  [[ "$f" == *.sig ]] && continue
  real_pkg_files+=("$f")
done

if [[ ${#real_pkg_files[@]} -eq 0 ]]; then
  echo "No packages in repo dir" >&2
  exit 1
fi

repo-add "$repo_dir/${repo_name}.db.tar.gz" "${real_pkg_files[@]}"

# repo-add may create .db/.files symlinks; create them only if missing.
[[ -e "$repo_dir/${repo_name}.db" ]] || ln -s "${repo_name}.db.tar.gz" "$repo_dir/${repo_name}.db"
[[ -e "$repo_dir/${repo_name}.files" ]] || ln -s "${repo_name}.files.tar.gz" "$repo_dir/${repo_name}.files"
EOS
)

docker run --rm \
  -e REPO_NAME="$repo_name" \
  -v "$combined_dir:/repo" \
  archlinux:base-devel \
  /bin/bash -lc "$repo_script"

upload_list=(
  "$combined_dir/${repo_name}.db.tar.gz"
  "$combined_dir/${repo_name}.db"
  "$combined_dir/${repo_name}.files.tar.gz"
  "$combined_dir/${repo_name}.files"
)

if [[ -n "${GPG_PRIVATE_KEY_B64:-}" && -n "${GPG_KEY_ID:-}" ]]; then
  gpg_home="$tmp_root/gnupg"
  mkdir -p "$gpg_home"
  chmod 700 "$gpg_home"
  export GNUPGHOME="$gpg_home"

  echo "$GPG_PRIVATE_KEY_B64" | base64 -d | gpg --batch --import

  sign_targets=(
    "$combined_dir/${repo_name}.db.tar.gz"
    "$combined_dir/${repo_name}.db"
    "$combined_dir/${repo_name}.files.tar.gz"
    "$combined_dir/${repo_name}.files"
  )

  for target in "${sign_targets[@]}"; do
    gpg --batch --yes --pinentry-mode loopback \
      --passphrase "${GPG_PASSPHRASE:-}" \
      --local-user "$GPG_KEY_ID" \
      --detach-sign --armor "$target"
    upload_list+=("$target.asc")
  done
fi

cp "$state_file" "$tmp_root/state.json"
upload_list+=("$tmp_root/state.json")

for selected in "${selected_files[@]}"; do
  upload_list+=("$selected_dir/$selected")
done

# Deduplicate upload paths.
mapfile -t upload_list < <(printf '%s\n' "${upload_list[@]}" | awk 'NF && !seen[$0]++')

if [[ ${#upload_list[@]} -gt 0 ]]; then
  gh release upload "$release_tag" --clobber "${upload_list[@]}"
fi

echo "Published release assets for $release_tag"
