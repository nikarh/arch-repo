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
sim_root="${MAKEPKG_DOCKER_SIM_ROOT:-}"

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

if [[ -n "$sim_root" ]]; then
  normalize_dep_name() {
    local dep_name="$1"
    dep_name="${dep_name%%[<>=]*}"
    dep_name="${dep_name%%:*}"
    dep_name="${dep_name//[[:space:]]/}"
    [[ -z "$dep_name" ]] && return 1
    [[ "$dep_name" == *".so"* || "$dep_name" == */* ]] && return 1
    printf '%s\n' "$dep_name"
  }

  parse_srcinfo_deps_from_file() {
    local srcinfo_file="$1"
    local dep_line dep_name
    while IFS= read -r dep_line; do
      dep_line="${dep_line#"${dep_line%%[![:space:]]*}"}"
      case "$dep_line" in
        "depends = "*|"makedepends = "*|"checkdepends = "*)
          dep_name="${dep_line#*= }"
          normalize_dep_name "$dep_name" || true
          ;;
      esac
    done < "$srcinfo_file" | awk '!seen[$0]++'
  }

  resolve_sim_aur_dep_closure() {
    local root_srcinfo="$1"
    local visited_file ordered_file
    visited_file="$(mktemp)"
    ordered_file="$(mktemp)"
    trap 'rm -f "$visited_file" "$ordered_file"' RETURN

    resolve_sim_dep_recursive() {
      local pkgname="$1"
      local dep_name dep_srcinfo
      dep_srcinfo="$sim_root/$pkgname/srcinfo"
      [[ -f "$dep_srcinfo" ]] || return 0

      if grep -Fxq "$pkgname" "$visited_file" 2>/dev/null; then
        return 0
      fi
      printf '%s\n' "$pkgname" >> "$visited_file"

      while IFS= read -r dep_name; do
        [[ -z "$dep_name" ]] && continue
        [[ -f "$sim_root/$dep_name/srcinfo" ]] || continue
        resolve_sim_dep_recursive "$dep_name"
      done < <(parse_srcinfo_deps_from_file "$dep_srcinfo")

      printf '%s\n' "$pkgname" >> "$ordered_file"
    }

    while IFS= read -r dep_name; do
      [[ -z "$dep_name" ]] && continue
      [[ -f "$sim_root/$dep_name/srcinfo" ]] || continue
      resolve_sim_dep_recursive "$dep_name"
    done < <(parse_srcinfo_deps_from_file "$root_srcinfo")

    awk '!seen[$0]++' "$ordered_file"
  }

  sim_copy_artifacts_for_pkg() {
    local pkgname="$1"
    local artifact
    shopt -s nullglob
    for artifact in "$sim_root/$pkgname/artifacts"/*; do
      cp -v "$artifact" "$out_dir/"
    done
  }

  sim_emit_packagelist_for_pkg() {
    local pkgname="$1"
    cat "$sim_root/$pkgname/packagelist.txt"
  }

  root_srcinfo="$src_dir/.codex-srcinfo"
  if [[ ! -f "$root_srcinfo" ]]; then
    echo "simulation mode requires $src_dir/.codex-srcinfo" >&2
    exit 1
  fi

  mapfile -t sim_dep_ids < <(resolve_sim_aur_dep_closure "$root_srcinfo")
  if [[ "$mode" == "list" ]]; then
    for dep_id in "${sim_dep_ids[@]}"; do
      sim_emit_packagelist_for_pkg "$dep_id"
    done
    cat "$src_dir/.codex-packagelist"
    exit 0
  fi

  for dep_id in "${sim_dep_ids[@]}"; do
    sim_copy_artifacts_for_pkg "$dep_id"
  done
  local_artifact_dir="$src_dir/.codex-artifacts"
  if [[ -d "$local_artifact_dir" ]]; then
    shopt -s nullglob
    for artifact in "$local_artifact_dir"/*; do
      cp -v "$artifact" "$out_dir/"
    done
  fi
  exit 0
fi

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

  awk '!seen[$0]++' "$ordered_file"
  rm -f "$deps_file" "$visited_file" "$ordered_file"
}

aur_pkgfile_patterns() {
  printf '%s\n' "*.pkg.tar.zst" "*.pkg.tar.xz" "*.pkg.tar.gz" "*.pkg.tar.bz2"
}

list_aur_dep_pkgfiles() {
  local dep_id="$1"
  local dep_root dep_src dep_pkgfile
  dep_root="$(mktemp -d)"
  dep_src="$dep_root/src"

  sudo -u "$build_user" git clone --depth=1 "https://aur.archlinux.org/${dep_id}.git" "$dep_src"
  (
    cd "$dep_src"
    sudo -u "$build_user" "${makepkg_cmd[@]}" --packagelist
  )
  rm -rf "$dep_root"
}

build_and_install_aur_dep() {
  local dep_id="$1"
  local dep_root dep_src built_pkg
  dep_root="$(mktemp -d)"
  dep_src="$dep_root/src"

  sudo -u "$build_user" git clone --depth=1 "https://aur.archlinux.org/${dep_id}.git" "$dep_src"
  (
    cd "$dep_src"
    sudo -u "$build_user" "${makepkg_cmd[@]}" --syncdeps --force --noconfirm --clean --cleanbuild --needed --noprogressbar --skippgpcheck
  )

  local -a built_pkgs=()
  shopt -s nullglob
  for built_pkg in "$dep_src"/*.pkg.tar.zst "$dep_src"/*.pkg.tar.xz "$dep_src"/*.pkg.tar.gz "$dep_src"/*.pkg.tar.bz2; do
    [[ -f "$built_pkg" ]] || continue
    built_pkgs+=("$built_pkg")
    copy_pkg_with_sig "$built_pkg"
  done
  if [[ ${#built_pkgs[@]} -gt 0 ]]; then
    pacman -U --noconfirm "${built_pkgs[@]}" >/dev/null
  fi
  rm -rf "$dep_root"
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
aur_dep_ids=()

if [[ "${ENABLE_AUR_DEPS:-1}" == "1" ]]; then
  mapfile -t aur_dep_ids < <(resolve_aur_dep_closure "$srcinfo")
fi

if [[ "$MODE" == "list" ]]; then
  for dep_id in "${aur_dep_ids[@]}"; do
    list_aur_dep_pkgfiles "$dep_id" | sed 's#^.*/##'
  done
  sudo -u "$build_user" "${makepkg_cmd[@]}" --packagelist | sed 's#^.*/##'
  exit 0
fi

for dep_id in "${aur_dep_ids[@]}"; do
  build_and_install_aur_dep "$dep_id"
done

sudo -u "$build_user" "${makepkg_cmd[@]}" --syncdeps --force --noconfirm --clean --cleanbuild --needed --noprogressbar --skippgpcheck

shopt -s nullglob
for f in ./*.pkg.tar.zst ./*.pkg.tar.xz ./*.pkg.tar.gz ./*.pkg.tar.bz2; do
  cp -v "$f" /out/
done
for sig in ./*.pkg.tar.zst.sig ./*.pkg.tar.xz.sig ./*.pkg.tar.gz.sig ./*.pkg.tar.bz2.sig; do
  cp -v "$sig" /out/
done
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

  awk '!seen[$0]++' "$ordered_file"
  rm -f "$deps_file" "$visited_file" "$ordered_file"
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

list_aur_dep_pkgfiles() {
  local dep_id="$1"
  local dep_root dep_src
  dep_root="$(mktemp -d)"
  dep_src="$dep_root/src"

  git clone --depth=1 "https://aur.archlinux.org/${dep_id}.git" "$dep_src"
  (
    cd "$dep_src"
    "${makepkg_cmd[@]}" --packagelist
  )
  rm -rf "$dep_root"
}

build_and_install_aur_dep() {
  local dep_id="$1"
  local dep_root dep_src built_pkg
  dep_root="$(mktemp -d)"
  dep_src="$dep_root/src"

  git clone --depth=1 "https://aur.archlinux.org/${dep_id}.git" "$dep_src"
  (
    cd "$dep_src"
    "${makepkg_cmd[@]}" --syncdeps --force --noconfirm --clean --cleanbuild --needed --noprogressbar --skippgpcheck
  )

  local -a built_pkgs=()
  shopt -s nullglob
  for built_pkg in "$dep_src"/*.pkg.tar.zst "$dep_src"/*.pkg.tar.xz "$dep_src"/*.pkg.tar.gz "$dep_src"/*.pkg.tar.bz2; do
    [[ -f "$built_pkg" ]] || continue
    built_pkgs+=("$built_pkg")
    copy_pkg_with_sig "$built_pkg"
  done
  if [[ ${#built_pkgs[@]} -gt 0 ]]; then
    sudo pacman -U --noconfirm "${built_pkgs[@]}" >/dev/null
  fi
  rm -rf "$dep_root"
}

aur_dep_ids=()

if [[ "${ENABLE_AUR_DEPS:-1}" == "1" ]]; then
  srcinfo="$(bash -lc "cd '$src_dir' && makepkg --printsrcinfo")"
  mapfile -t aur_dep_ids < <(resolve_aur_dep_closure "$srcinfo")
fi

if [[ "$mode" == "list" ]]; then
  for dep_id in "${aur_dep_ids[@]}"; do
    list_aur_dep_pkgfiles "$dep_id" | sed 's#^.*/##'
  done
  (
    cd "$src_dir"
    "${makepkg_cmd[@]}" --packagelist
  ) | sed 's#^.*/##'
  exit 0
fi

for dep_id in "${aur_dep_ids[@]}"; do
  build_and_install_aur_dep "$dep_id"
done

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
