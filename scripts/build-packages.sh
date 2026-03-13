#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <arch> <out_dir>" >&2
  exit 1
fi

arch="$1"
out_dir="$(realpath -m "$2")"
config_file="packages.json"

if [[ ! -f "$config_file" ]]; then
  echo "missing $config_file" >&2
  exit 1
fi

mkdir -p "$out_dir"
work_root="$(mktemp -d)"
manifest_tmp="$work_root/manifest.ndjson"
trap 'rm -rf "$work_root"' EXIT

count=$(jq --arg arch "$arch" '[.packages[] | select((.arches // ["x86_64","aarch64"]) | index($arch))] | length' "$config_file")
if [[ "$count" -eq 0 ]]; then
  echo "No packages configured for arch=$arch"
fi

jq -c --arg arch "$arch" '.packages[] | select((.arches // ["x86_64","aarch64"]) | index($arch))' "$config_file" | \
while IFS= read -r pkg; do
  pkg_id=$(jq -r '.id' <<<"$pkg")
  pkg_type=$(jq -r '.type' <<<"$pkg")
  pkg_work="$work_root/$pkg_id"
  src_dir="$pkg_work/src"
  mkdir -p "$src_dir"

  echo "==> building $pkg_id ($pkg_type) for $arch"

  case "$pkg_type" in
    aur)
      aur_name=$(jq -r '.aur' <<<"$pkg")
      git clone --depth=1 "https://aur.archlinux.org/${aur_name}.git" "$src_dir"
      ;;
    local)
      local_path=$(jq -r '.path' <<<"$pkg")
      cp -a "$local_path"/. "$src_dir"/
      ;;
    *)
      echo "unsupported package type for $pkg_id: $pkg_type" >&2
      exit 1
      ;;
  esac

  "$PWD/scripts/makepkg-docker.sh" "$arch" "$src_dir" "$out_dir"
done

shopt -s nullglob
for pkgfile in "$out_dir"/*.pkg.tar.*; do
  [[ "$pkgfile" == *.sig ]] && continue
  filename=$(basename "$pkgfile")
  if [[ ! "$filename" =~ ^(.+)-([^-]+)-([^-]+)-([^-]+)\.pkg\.tar\..+$ ]]; then
    echo "unable to parse package filename: $filename" >&2
    exit 1
  fi

  pkgname="${BASH_REMATCH[1]}"
  pkgver="${BASH_REMATCH[2]}"
  pkgrel="${BASH_REMATCH[3]}"
  pkgarch="${BASH_REMATCH[4]}"
  sha256=$(sha256sum "$pkgfile" | awk '{print $1}')

  jq -nc \
    --arg pkgname "$pkgname" \
    --arg version "$pkgver-$pkgrel" \
    --arg arch "$pkgarch" \
    --arg filename "$filename" \
    --arg sha256 "$sha256" \
    '{pkgname:$pkgname, version:$version, arch:$arch, filename:$filename, sha256:$sha256}' >> "$manifest_tmp"
done

jq -s '.' "$manifest_tmp" > "$out_dir/manifest.json"
echo "Wrote manifest to $out_dir/manifest.json"
