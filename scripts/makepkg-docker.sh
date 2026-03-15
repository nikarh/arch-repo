#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 <arch> <src_dir> <out_dir> [build|list]" >&2
  exit 1
fi

arch="$1"
src_dir="$(realpath "$2")"
out_dir="$(realpath -m "$3")"
mode="${4:-build}"

case "$arch" in
  x86_64)
    docker_platform='linux/amd64'
    docker_image='archlinux:base-devel'
    ;;
  aarch64)
    docker_platform='linux/arm64'
    docker_image='agners/archlinuxarm:latest'
    ;;
  *)
    echo "unsupported arch: $arch" >&2
    exit 1
    ;;
esac

case "$mode" in
  build|list) ;;
  *)
    echo "unsupported mode: $mode" >&2
    exit 1
    ;;
esac

mkdir -p "$out_dir"

makepkg_config_setup=$(cat <<'EOS'
makepkg_cmd=()
if [[ "${BUILD_AUTO_DEBUG_PACKAGES:-false}" == "true" ]]; then
  makepkg_cmd=(makepkg)
else
  base_makepkg_conf="/etc/makepkg.conf"
  custom_makepkg_conf="$(mktemp)"
  # Force-disable auto-generated debug split packages regardless of the image defaults.
  awk '
    BEGIN { replaced = 0 }
    /^[[:space:]]*OPTIONS=\(/ {
      line = $0
      gsub(/\<debug\>/, "!debug", line)
      print line
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        print "OPTIONS=(!debug)"
      }
    }
  ' "$base_makepkg_conf" > "$custom_makepkg_conf"
  chmod 0644 "$custom_makepkg_conf"
  makepkg_cmd=(makepkg --config "$custom_makepkg_conf")
fi
trap '[[ -n "${custom_makepkg_conf:-}" ]] && rm -f "$custom_makepkg_conf"' EXIT
EOS
)

container_script=$(cat <<'EOS'
set -euo pipefail
export HOME=/root
# Needed for some GitHub runners/containers where pacman sandbox cannot initialize.
disable_sandbox_set=0
while IFS= read -r line; do
  if [[ "$line" == "DisableSandbox" ]]; then
    disable_sandbox_set=1
    break
  fi
done < /etc/pacman.conf
if [[ "$disable_sandbox_set" -eq 0 ]]; then
  sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
fi
pacman -Syu --noconfirm --needed archlinux-keyring >/dev/null
pacman -S --noconfirm --needed base-devel git sudo gnupg curl jq >/dev/null
if [[ -n "${EXTRA_BUILD_DEPS:-}" ]]; then
  pacman -S --noconfirm --needed ${EXTRA_BUILD_DEPS} >/dev/null
fi

host_uid="$(stat -c '%u' /src)"
host_gid="$(stat -c '%g' /src)"

if ! getent group "$host_gid" >/dev/null 2>&1; then
  groupadd -g "$host_gid" hostgroup
fi
if ! getent passwd "$host_uid" >/dev/null 2>&1; then
  useradd -m -u "$host_uid" -g "$host_gid" builder
fi
build_user="$(getent passwd "$host_uid" | cut -d: -f1)"

echo "$build_user ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/builder-pacman
chmod 0440 /etc/sudoers.d/builder-pacman

cd /src

pre_yay_pkgfiles="$(mktemp)"
post_yay_pkgfiles="$(mktemp)"
aur_dep_ids_file="$(mktemp)"
matched_aur_dep_ids_file="$(mktemp)"
trap 'rm -f "$pre_yay_pkgfiles" "$post_yay_pkgfiles" "$aur_dep_ids_file" "$matched_aur_dep_ids_file"' EXIT

snapshot_yay_pkgfiles() {
  local outfile="$1"
  : > "$outfile"
  local root
  for root in "/home/$build_user/.cache/yay" "/root/.cache/yay" "/var/cache/pacman/pkg"; do
    [[ -d "$root" ]] || continue
    find "$root" -type f -name '*.pkg.tar.*' ! -name '*.sig' | sort -u >> "$outfile"
  done
  sort -u -o "$outfile" "$outfile"
}

copy_pkg_with_sig() {
  local pkgfile="$1"
  [[ -f "$pkgfile" ]] || return 0
  cp -v "$pkgfile" /out/
  [[ -f "$pkgfile.sig" ]] && cp -v "$pkgfile.sig" /out/
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

pkgfile_name_to_pkgname() {
  local filename
  filename="$(basename "$1")"
  if [[ "$filename" =~ ^(.+)-([^-]+)-([^-]+)-([^-]+)\.pkg\.tar\..+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

parse_srcinfo_deps() {
  local srcinfo="$1"
  local dep_line dep_name
  while IFS= read -r dep_line; do
    dep_line="${dep_line#"${dep_line%%[![:space:]]*}"}"
    case "$dep_line" in
      "depends = "*|"makedepends = "*|"checkdepends = "*)
        dep_name="${dep_line#*= }"
        if dep_name="$(normalize_dep_name "$dep_name")"; then
          printf '%s\n' "$dep_name"
        fi
        ;;
    esac
  done <<< "$srcinfo" | sort -u
}

aur_rpc_info() {
  local pkgname="$1"
  curl -fsSL "https://aur.archlinux.org/rpc/?v=5&type=info&arg[]=${pkgname}"
}

is_official_or_installed_package() {
  local pkgname="$1"
  pacman -Si "$pkgname" >/dev/null 2>&1 || pacman -Q "$pkgname" >/dev/null 2>&1
}

is_aur_package() {
  local pkgname="$1"
  aur_rpc_info "$pkgname" | jq -e '.resultcount > 0' >/dev/null 2>&1
}

aur_rpc_dep_names() {
  local pkgname="$1"
  aur_rpc_info "$pkgname" | jq -r '
    .results[0] as $pkg
    | (($pkg.Depends // []) + ($pkg.MakeDepends // []) + ($pkg.CheckDepends // []))[]
  ' | while IFS= read -r dep_name; do
    normalize_dep_name "$dep_name" || true
  done | sort -u
}

resolve_aur_dep_closure() {
  local srcinfo="$1"
  local deps_file visited_file ordered_file
  deps_file="$(mktemp)"
  visited_file="$(mktemp)"
  ordered_file="$(mktemp)"

  parse_srcinfo_deps "$srcinfo" > "$deps_file"

  resolve_aur_dep_recursive() {
    local pkgname="$1"
    local dep_name

    if grep -Fxq "$pkgname" "$visited_file" 2>/dev/null; then
      return 0
    fi
    printf '%s\n' "$pkgname" >> "$visited_file"

    while IFS= read -r dep_name; do
      [[ -z "$dep_name" ]] && continue
      if is_official_or_installed_package "$dep_name"; then
        continue
      fi
      if is_aur_package "$dep_name"; then
        resolve_aur_dep_recursive "$dep_name"
      fi
    done < <(aur_rpc_dep_names "$pkgname")

    printf '%s\n' "$pkgname" >> "$ordered_file"
  }

  while IFS= read -r dep_name; do
    [[ -z "$dep_name" ]] && continue
    if is_official_or_installed_package "$dep_name"; then
      continue
    fi
    if is_aur_package "$dep_name"; then
      resolve_aur_dep_recursive "$dep_name"
    fi
  done < "$deps_file"

  sort -u "$ordered_file"
  rm -f "$deps_file" "$visited_file" "$ordered_file"
}

find_cache_pkgfiles_for_ids() {
  local ids_file="$1"
  local pkgfile pkgname
  [[ -s "$ids_file" ]] || return 0
  while IFS= read -r pkgfile; do
    [[ -f "$pkgfile" ]] || continue
    pkgname="$(pkgfile_name_to_pkgname "$pkgfile" || true)"
    [[ -z "$pkgname" ]] && continue
    if grep -Fxq "$pkgname" "$ids_file"; then
      printf '%s\n' "$pkgfile"
    fi
  done < "$post_yay_pkgfiles" | sort -u
}

build_missing_aur_dep() {
  local dep_id="$1"
  local dep_root dep_src dep_out
  dep_root="$(mktemp -d)"
  dep_src="$dep_root/src"
  dep_out="$dep_root/out"
  mkdir -p "$dep_out"

  sudo -u "$build_user" git clone --depth=1 "https://aur.archlinux.org/${dep_id}.git" "$dep_src"
  (
    cd "$dep_src"
    sudo -u "$build_user" "${makepkg_cmd[@]}" --syncdeps --force --noconfirm --clean --cleanbuild --needed --noprogressbar --skippgpcheck
  )

  local built_pkg built_pkgname
  shopt -s nullglob
  for built_pkg in "$dep_src"/*.pkg.tar.zst "$dep_src"/*.pkg.tar.xz "$dep_src"/*.pkg.tar.gz "$dep_src"/*.pkg.tar.bz2; do
    built_pkgname="$(pkgfile_name_to_pkgname "$built_pkg" || true)"
    [[ -z "$built_pkgname" ]] && continue
    copy_pkg_with_sig "$built_pkg"
  done
  rm -rf "$dep_root"
}

write_matched_aur_dep_ids() {
  : > "$matched_aur_dep_ids_file"
  local dep_pkg dep_pkgname
  for dep_pkg in "${aur_dep_pkgfiles[@]}"; do
    dep_pkgname="$(pkgfile_name_to_pkgname "$dep_pkg" || true)"
    [[ -z "$dep_pkgname" ]] && continue
    printf '%s\n' "$dep_pkgname" >> "$matched_aur_dep_ids_file"
  done
  sort -u -o "$matched_aur_dep_ids_file" "$matched_aur_dep_ids_file"
}

install_yay() {
  if command -v yay >/dev/null 2>&1; then
    return 0
  fi
  tmp_yay="$(mktemp -d)"
  chown "$host_uid:$host_gid" "$tmp_yay"
  sudo -u "$build_user" git clone --depth=1 https://aur.archlinux.org/yay.git "$tmp_yay/yay"
  sudo -u "$build_user" bash -lc "cd '$tmp_yay/yay' && makepkg --syncdeps --noconfirm --needed --clean --skippgpcheck"
  yay_pkg="$(find "$tmp_yay/yay" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' | head -n1)"
  if [[ -z "$yay_pkg" ]]; then
    echo "failed to build yay package" >&2
    exit 1
  fi
  pacman -U --noconfirm "$yay_pkg" >/dev/null
  rm -rf "$tmp_yay"
}

srcinfo="$(sudo -u "$build_user" makepkg --printsrcinfo)"
aur_dep_pkgfiles=()
aur_dep_ids=()

if [[ "${ENABLE_AUR_DEPS:-1}" == "1" ]]; then
  mapfile -t aur_dep_ids < <(resolve_aur_dep_closure "$srcinfo")
  if [[ ${#aur_dep_ids[@]} -gt 0 ]]; then
    printf '%s\n' "${aur_dep_ids[@]}" > "$aur_dep_ids_file"
  fi

  snapshot_yay_pkgfiles "$pre_yay_pkgfiles"
  if [[ ${#aur_dep_ids[@]} -gt 0 ]]; then
    install_yay
    sudo -u "$build_user" yay -S --noconfirm --needed --asdeps \
      --mflags "--noconfirm --needed --skippgpcheck" \
      --answerclean None \
      --answerdiff None \
      "${aur_dep_ids[@]}"
  fi
  snapshot_yay_pkgfiles "$post_yay_pkgfiles"
  if [[ -s "$aur_dep_ids_file" && -s "$post_yay_pkgfiles" ]]; then
    mapfile -t aur_dep_pkgfiles < <(find_cache_pkgfiles_for_ids "$aur_dep_ids_file")
  fi
  write_matched_aur_dep_ids
fi

if [[ "$MODE" == "list" ]]; then
  if [[ ${#aur_dep_pkgfiles[@]} -gt 0 ]]; then
    printf '%s\n' "${aur_dep_pkgfiles[@]}" | sed 's#^.*/##'
  fi
  if [[ -s "$aur_dep_ids_file" ]]; then
    dep_tmp=""
    while IFS= read -r dep_id; do
      [[ -z "$dep_id" ]] && continue
      if grep -Fxq "$dep_id" "$matched_aur_dep_ids_file"; then
        continue
      fi
      dep_tmp="$(mktemp -d)"
      sudo -u "$build_user" git clone --depth=1 "https://aur.archlinux.org/${dep_id}.git" "$dep_tmp/src"
      (
        cd "$dep_tmp/src"
        sudo -u "$build_user" "${makepkg_cmd[@]}" --packagelist
      ) | sed 's#^.*/##'
      rm -rf "$dep_tmp"
      dep_tmp=""
    done < "$aur_dep_ids_file"
    [[ -n "$dep_tmp" ]] && rm -rf "$dep_tmp"
  fi
  sudo -u "$build_user" "${makepkg_cmd[@]}" --packagelist | sed 's#^.*/##'
  exit 0
fi

sudo -u "$build_user" "${makepkg_cmd[@]}" --syncdeps --force --noconfirm --clean --cleanbuild --needed --noprogressbar --skippgpcheck

shopt -s nullglob
for f in ./*.pkg.tar.zst ./*.pkg.tar.xz ./*.pkg.tar.gz ./*.pkg.tar.bz2; do
  cp -v "$f" /out/
done
for sig in ./*.pkg.tar.zst.sig ./*.pkg.tar.xz.sig ./*.pkg.tar.gz.sig ./*.pkg.tar.bz2.sig; do
  cp -v "$sig" /out/
done
for dep_pkg in "${aur_dep_pkgfiles[@]}"; do
  copy_pkg_with_sig "$dep_pkg"
done

if [[ -s "$aur_dep_ids_file" ]]; then
  while IFS= read -r dep_id; do
    [[ -z "$dep_id" ]] && continue
    if grep -Fxq "$dep_id" "$matched_aur_dep_ids_file"; then
      continue
    fi
    build_missing_aur_dep "$dep_id"
  done < "$aur_dep_ids_file"
fi
EOS
)
container_script="${container_script/cd \/src/$'cd /src\n'"$makepkg_config_setup"}"

if command -v docker >/dev/null 2>&1; then
  docker run --rm \
    --platform "$docker_platform" \
    -e MODE="$mode" \
    -e EXTRA_BUILD_DEPS="${EXTRA_BUILD_DEPS:-}" \
    -e BUILD_AUTO_DEBUG_PACKAGES="${BUILD_AUTO_DEBUG_PACKAGES:-false}" \
    -v "$src_dir:/src" \
    -v "$out_dir:/out" \
    "$docker_image" \
    /bin/bash -lc "$container_script"
  exit 0
fi

# Local fallback for environments without Docker (used for local validation only).
if [[ "$arch" != "x86_64" ]]; then
  echo "docker not found and local fallback only supports x86_64" >&2
  exit 1
fi

if ! command -v pacman >/dev/null 2>&1; then
  echo "docker not found and pacman unavailable for local fallback" >&2
  exit 1
fi

sudo pacman -Syu --noconfirm --needed archlinux-keyring base-devel git sudo curl jq >/dev/null
if [[ -n "${EXTRA_BUILD_DEPS:-}" ]]; then
  sudo pacman -S --noconfirm --needed ${EXTRA_BUILD_DEPS} >/dev/null
fi
eval "$makepkg_config_setup"

pre_yay_pkgfiles="$(mktemp)"
post_yay_pkgfiles="$(mktemp)"
aur_dep_ids_file="$(mktemp)"
matched_aur_dep_ids_file="$(mktemp)"
trap 'rm -f "$pre_yay_pkgfiles" "$post_yay_pkgfiles" "$aur_dep_ids_file" "$matched_aur_dep_ids_file"' EXIT

snapshot_yay_pkgfiles() {
  local outfile="$1"
  : > "$outfile"
  local root
  for root in "${HOME}/.cache/yay" "/root/.cache/yay" "/var/cache/pacman/pkg"; do
    [[ -d "$root" ]] || continue
    find "$root" -type f -name '*.pkg.tar.*' ! -name '*.sig' | sort -u >> "$outfile"
  done
  sort -u -o "$outfile" "$outfile"
}

copy_pkg_with_sig() {
  local pkgfile="$1"
  [[ -f "$pkgfile" ]] || return 0
  cp -v "$pkgfile" "$out_dir/"
  [[ -f "$pkgfile.sig" ]] && cp -v "$pkgfile.sig" "$out_dir/"
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

pkgfile_name_to_pkgname() {
  local filename
  filename="$(basename "$1")"
  if [[ "$filename" =~ ^(.+)-([^-]+)-([^-]+)-([^-]+)\.pkg\.tar\..+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

parse_srcinfo_deps() {
  local srcinfo="$1"
  local dep_line dep_name
  while IFS= read -r dep_line; do
    dep_line="${dep_line#"${dep_line%%[![:space:]]*}"}"
    case "$dep_line" in
      "depends = "*|"makedepends = "*|"checkdepends = "*)
        dep_name="${dep_line#*= }"
        if dep_name="$(normalize_dep_name "$dep_name")"; then
          printf '%s\n' "$dep_name"
        fi
        ;;
    esac
  done <<< "$srcinfo" | sort -u
}

aur_rpc_info() {
  local pkgname="$1"
  curl -fsSL "https://aur.archlinux.org/rpc/?v=5&type=info&arg[]=${pkgname}"
}

is_official_or_installed_package() {
  local pkgname="$1"
  pacman -Si "$pkgname" >/dev/null 2>&1 || pacman -Q "$pkgname" >/dev/null 2>&1
}

is_aur_package() {
  local pkgname="$1"
  aur_rpc_info "$pkgname" | jq -e '.resultcount > 0' >/dev/null 2>&1
}

aur_rpc_dep_names() {
  local pkgname="$1"
  aur_rpc_info "$pkgname" | jq -r '
    .results[0] as $pkg
    | (($pkg.Depends // []) + ($pkg.MakeDepends // []) + ($pkg.CheckDepends // []))[]
  ' | while IFS= read -r dep_name; do
    normalize_dep_name "$dep_name" || true
  done | sort -u
}

resolve_aur_dep_closure() {
  local srcinfo="$1"
  local deps_file visited_file ordered_file
  deps_file="$(mktemp)"
  visited_file="$(mktemp)"
  ordered_file="$(mktemp)"

  parse_srcinfo_deps "$srcinfo" > "$deps_file"

  resolve_aur_dep_recursive() {
    local pkgname="$1"
    local dep_name

    if grep -Fxq "$pkgname" "$visited_file" 2>/dev/null; then
      return 0
    fi
    printf '%s\n' "$pkgname" >> "$visited_file"

    while IFS= read -r dep_name; do
      [[ -z "$dep_name" ]] && continue
      if is_official_or_installed_package "$dep_name"; then
        continue
      fi
      if is_aur_package "$dep_name"; then
        resolve_aur_dep_recursive "$dep_name"
      fi
    done < <(aur_rpc_dep_names "$pkgname")

    printf '%s\n' "$pkgname" >> "$ordered_file"
  }

  while IFS= read -r dep_name; do
    [[ -z "$dep_name" ]] && continue
    if is_official_or_installed_package "$dep_name"; then
      continue
    fi
    if is_aur_package "$dep_name"; then
      resolve_aur_dep_recursive "$dep_name"
    fi
  done < "$deps_file"

  sort -u "$ordered_file"
  rm -f "$deps_file" "$visited_file" "$ordered_file"
}

find_cache_pkgfiles_for_ids() {
  local ids_file="$1"
  local pkgfile pkgname
  [[ -s "$ids_file" ]] || return 0
  while IFS= read -r pkgfile; do
    [[ -f "$pkgfile" ]] || continue
    pkgname="$(pkgfile_name_to_pkgname "$pkgfile" || true)"
    [[ -z "$pkgname" ]] && continue
    if grep -Fxq "$pkgname" "$ids_file"; then
      printf '%s\n' "$pkgfile"
    fi
  done < "$post_yay_pkgfiles" | sort -u
}

write_matched_aur_dep_ids() {
  : > "$matched_aur_dep_ids_file"
  local dep_pkg dep_pkgname
  for dep_pkg in "${aur_dep_pkgfiles[@]}"; do
    dep_pkgname="$(pkgfile_name_to_pkgname "$dep_pkg" || true)"
    [[ -z "$dep_pkgname" ]] && continue
    printf '%s\n' "$dep_pkgname" >> "$matched_aur_dep_ids_file"
  done
  sort -u -o "$matched_aur_dep_ids_file" "$matched_aur_dep_ids_file"
}

ensure_local_yay() {
  if command -v yay >/dev/null 2>&1; then
    return 0
  fi
  local tmp_yay yay_pkg
  tmp_yay="$(mktemp -d)"
  git clone --depth=1 https://aur.archlinux.org/yay.git "$tmp_yay/yay"
  bash -lc "cd '$tmp_yay/yay' && makepkg --syncdeps --noconfirm --needed --clean --skippgpcheck"
  yay_pkg="$(find "$tmp_yay/yay" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' | head -n1)"
  if [[ -z "$yay_pkg" ]]; then
    echo "failed to build yay package" >&2
    exit 1
  fi
  sudo pacman -U --noconfirm "$yay_pkg" >/dev/null
  rm -rf "$tmp_yay"
}

build_missing_aur_dep() {
  local dep_id="$1"
  local dep_root dep_src built_pkg built_pkgname
  dep_root="$(mktemp -d)"
  dep_src="$dep_root/src"

  git clone --depth=1 "https://aur.archlinux.org/${dep_id}.git" "$dep_src"
  (
    cd "$dep_src"
    "${makepkg_cmd[@]}" --syncdeps --force --noconfirm --clean --cleanbuild --needed --noprogressbar --skippgpcheck
  )

  shopt -s nullglob
  for built_pkg in "$dep_src"/*.pkg.tar.zst "$dep_src"/*.pkg.tar.xz "$dep_src"/*.pkg.tar.gz "$dep_src"/*.pkg.tar.bz2; do
    built_pkgname="$(pkgfile_name_to_pkgname "$built_pkg" || true)"
    [[ -z "$built_pkgname" ]] && continue
    copy_pkg_with_sig "$built_pkg"
  done
  rm -rf "$dep_root"
}

aur_dep_pkgfiles=()
aur_dep_ids=()

if [[ "${ENABLE_AUR_DEPS:-1}" == "1" ]]; then
  snapshot_yay_pkgfiles "$pre_yay_pkgfiles"
  srcinfo="$(bash -lc "cd '$src_dir' && makepkg --printsrcinfo")"
  mapfile -t aur_dep_ids < <(resolve_aur_dep_closure "$srcinfo")
  if [[ ${#aur_dep_ids[@]} -gt 0 ]]; then
    printf '%s\n' "${aur_dep_ids[@]}" > "$aur_dep_ids_file"
    ensure_local_yay
    yay -S --noconfirm --needed --asdeps \
      --mflags "--noconfirm --needed --skippgpcheck" \
      --answerclean None \
      --answerdiff None \
      "${aur_dep_ids[@]}"
  fi
  snapshot_yay_pkgfiles "$post_yay_pkgfiles"
  if [[ -s "$aur_dep_ids_file" && -s "$post_yay_pkgfiles" ]]; then
    mapfile -t aur_dep_pkgfiles < <(find_cache_pkgfiles_for_ids "$aur_dep_ids_file")
  fi
  write_matched_aur_dep_ids
fi

if [[ "$mode" == "list" ]]; then
  if [[ ${#aur_dep_pkgfiles[@]} -gt 0 ]]; then
    printf '%s\n' "${aur_dep_pkgfiles[@]}" | sed 's#^.*/##'
  fi
  if [[ -s "$aur_dep_ids_file" ]]; then
    dep_tmp=""
    while IFS= read -r dep_id; do
      [[ -z "$dep_id" ]] && continue
      if grep -Fxq "$dep_id" "$matched_aur_dep_ids_file"; then
        continue
      fi
      dep_tmp="$(mktemp -d)"
      git clone --depth=1 "https://aur.archlinux.org/${dep_id}.git" "$dep_tmp/src"
      (
        cd "$dep_tmp/src"
        "${makepkg_cmd[@]}" --packagelist
      ) | sed 's#^.*/##'
      rm -rf "$dep_tmp"
      dep_tmp=""
    done < "$aur_dep_ids_file"
    [[ -n "$dep_tmp" ]] && rm -rf "$dep_tmp"
  fi
  (
    cd "$src_dir"
    "${makepkg_cmd[@]}" --packagelist
  ) | sed 's#^.*/##'
  exit 0
fi

(
  cd "$src_dir"
  "${makepkg_cmd[@]}" --syncdeps --force --noconfirm --clean --cleanbuild --needed --noprogressbar --skippgpcheck
)

shopt -s nullglob
for f in "$src_dir"/*.pkg.tar.zst "$src_dir"/*.pkg.tar.xz "$src_dir"/*.pkg.tar.gz "$src_dir"/*.pkg.tar.bz2; do
  cp -v "$f" "$out_dir/"
done
for sig in "$src_dir"/*.pkg.tar.zst.sig "$src_dir"/*.pkg.tar.xz.sig "$src_dir"/*.pkg.tar.gz.sig "$src_dir"/*.pkg.tar.bz2.sig; do
  cp -v "$sig" "$out_dir/"
done
for dep_pkg in "${aur_dep_pkgfiles[@]}"; do
  copy_pkg_with_sig "$dep_pkg"
done
if [[ -s "$aur_dep_ids_file" ]]; then
  while IFS= read -r dep_id; do
    [[ -z "$dep_id" ]] && continue
    if grep -Fxq "$dep_id" "$matched_aur_dep_ids_file"; then
      continue
    fi
    build_missing_aur_dep "$dep_id"
  done < "$aur_dep_ids_file"
fi
