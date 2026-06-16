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
shared_artifact_dir="${MAKEPKG_SHARED_ARTIFACT_DIR:-}"
if [[ -n "$shared_artifact_dir" ]]; then
  shared_artifact_dir="$(realpath -m "$shared_artifact_dir")"
fi

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
  if [[ "$mode" == "list" ]]; then
    cat "$src_dir/.codex-packagelist"
    exit 0
  fi

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

builder_script=$(cat <<'EOS'
set -euo pipefail

configure_prebuilt_repo() {
  local repo_name="${PREBUILT_REPO_NAME:-}"
  local repo_url="${PREBUILT_REPO_URL:-}"
  [[ -n "$repo_name" && -n "$repo_url" ]] || return 0
  if ! grep -Fxq "[$repo_name]" /etc/pacman.conf 2>/dev/null; then
    {
      printf '\n[%s]\n' "$repo_name"
      printf 'SigLevel = Never\n'
      printf 'Server = %s\n' "$repo_url"
    } >> /etc/pacman.conf
  fi
  pacman -Sy --noconfirm >/dev/null
}

if [[ "${IN_DOCKER:-0}" == "1" ]]; then
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
  configure_prebuilt_repo

  host_uid="$(stat -c '%u' "$SRC_DIR")"
  host_gid="$(stat -c '%g' "$SRC_DIR")"

  if ! getent group "$host_gid" >/dev/null 2>&1; then
    groupadd -g "$host_gid" hostgroup
  fi
  if ! getent passwd "$host_uid" >/dev/null 2>&1; then
    useradd -m -u "$host_uid" -g "$host_gid" builder
  fi
  build_user="$(getent passwd "$host_uid" | cut -d: -f1)"

  echo "$build_user ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/builder-pacman
  chmod 0440 /etc/sudoers.d/builder-pacman
else
  configure_prebuilt_repo
  build_user=""
fi

if [[ -n "${EXTRA_BUILD_DEPS:-}" ]]; then
  pacman -S --noconfirm --needed ${EXTRA_BUILD_DEPS} >/dev/null
fi

cd "$SRC_DIR"
MAKEPKG_CONFIG_SETUP_PLACEHOLDER

run_makepkg() {
  if [[ -n "${build_user:-}" ]]; then
    sudo -u "$build_user" "${makepkg_cmd[@]}" "$@"
  else
    "${makepkg_cmd[@]}" "$@"
  fi
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

parse_srcinfo_deps() {
  local srcinfo="$1"
  local dep_line dep_name field
  while IFS= read -r dep_line; do
    dep_line="${dep_line#"${dep_line%%[![:space:]]*}"}"
    field="${dep_line%% = *}"
    case "$field" in
      depends|makedepends|checkdepends|depends_*|makedepends_*|checkdepends_*)
        dep_name="${dep_line#*= }"
        normalize_dep_name "$dep_name" || true
        ;;
    esac
  done <<< "$srcinfo" | sort -u
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

is_official_or_installed_package() {
  local pkgname="$1"
  pacman -Si "$pkgname" >/dev/null 2>&1 || pacman -Q "$pkgname" >/dev/null 2>&1
}

pkgfile_provides_dep() {
  local pkgfile="$1"
  local dep_name="$2"
  bsdtar -xOf "$pkgfile" .PKGINFO 2>/dev/null \
    | awk -F' = ' '$1 == "provides" { print $2 }' \
    | while IFS= read -r provided; do
        normalize_dep_name "$provided" || true
      done \
    | grep -Fxq "$dep_name"
}

find_shared_pkgfiles_for_dep() {
  local dep_name="$1"
  local pkgfile pkgname
  [[ -n "${SHARED_ARTIFACT_DIR:-}" && -d "${SHARED_ARTIFACT_DIR:-}" ]] || return 0

  shopt -s nullglob
  for pkgfile in "$SHARED_ARTIFACT_DIR"/*.pkg.tar.*; do
    [[ "$pkgfile" == *.sig ]] && continue
    if pkgname="$(pkgfile_name_to_pkgname "$pkgfile")" && [[ "$pkgname" == "$dep_name" ]]; then
      printf '%s\n' "$pkgfile"
      continue
    fi
    if pkgfile_provides_dep "$pkgfile" "$dep_name"; then
      printf '%s\n' "$pkgfile"
    fi
  done
}

install_shared_dependency_packages() {
  local srcinfo="$1"
  local dep_name pkgfile
  local -a dep_pkgfiles=()
  local -a pkgfiles=()

  while IFS= read -r dep_name; do
    [[ -z "$dep_name" ]] && continue
    dep_pkgfiles=()
    while IFS= read -r pkgfile; do
      [[ -z "$pkgfile" ]] && continue
      dep_pkgfiles+=("$pkgfile")
    done < <(find_shared_pkgfiles_for_dep "$dep_name")

    if [[ ${#dep_pkgfiles[@]} -gt 0 ]]; then
      pkgfiles+=("${dep_pkgfiles[@]}")
      continue
    fi

    if is_official_or_installed_package "$dep_name"; then
      continue
    fi
  done < <(parse_srcinfo_deps "$srcinfo")

  if [[ ${#pkgfiles[@]} -eq 0 ]]; then
    return 0
  fi

  mapfile -t pkgfiles < <(printf '%s\n' "${pkgfiles[@]}" | sort -u)
  pacman -U --noconfirm "${pkgfiles[@]}" >/dev/null
}

if [[ "$MODE" == "list" ]]; then
  run_makepkg --packagelist | sed 's#^.*/##'
  exit 0
fi

srcinfo="$(run_makepkg --printsrcinfo)"
install_shared_dependency_packages "$srcinfo"
run_makepkg --syncdeps --force --noconfirm --clean --cleanbuild --needed --noprogressbar --skippgpcheck

shopt -s nullglob
for f in ./*.pkg.tar.zst ./*.pkg.tar.xz ./*.pkg.tar.gz ./*.pkg.tar.bz2; do
  cp -v "$f" "$OUT_DIR/"
done
for sig in ./*.pkg.tar.zst.sig ./*.pkg.tar.xz.sig ./*.pkg.tar.gz.sig ./*.pkg.tar.bz2.sig; do
  cp -v "$sig" "$OUT_DIR/"
done
EOS
)
builder_script="${builder_script/MAKEPKG_CONFIG_SETUP_PLACEHOLDER/$makepkg_config_setup}"

if command -v docker >/dev/null 2>&1; then
  docker_args=(
    run --rm
    --platform "$docker_platform"
    -e IN_DOCKER=1
    -e MODE="$mode"
    -e SRC_DIR=/src
    -e OUT_DIR=/out
    -e EXTRA_BUILD_DEPS="${EXTRA_BUILD_DEPS:-}"
    -e BUILD_AUTO_DEBUG_PACKAGES="${BUILD_AUTO_DEBUG_PACKAGES:-false}"
    -e PREBUILT_REPO_NAME="${PREBUILT_REPO_NAME:-}"
    -e PREBUILT_REPO_URL="${PREBUILT_REPO_URL:-}"
    -v "$src_dir:/src"
    -v "$out_dir:/out"
  )
  if [[ -n "$shared_artifact_dir" ]]; then
    docker_args+=(-e SHARED_ARTIFACT_DIR=/shared-artifacts -v "$shared_artifact_dir:/shared-artifacts")
  fi
  docker "${docker_args[@]}" "$docker_image" /bin/bash -lc "$builder_script"
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

local_env=(
  IN_DOCKER=0
  MODE="$mode"
  SRC_DIR="$src_dir"
  OUT_DIR="$out_dir"
  EXTRA_BUILD_DEPS="${EXTRA_BUILD_DEPS:-}"
  BUILD_AUTO_DEBUG_PACKAGES="${BUILD_AUTO_DEBUG_PACKAGES:-false}"
  PREBUILT_REPO_NAME="${PREBUILT_REPO_NAME:-}"
  PREBUILT_REPO_URL="${PREBUILT_REPO_URL:-}"
)
if [[ -n "$shared_artifact_dir" ]]; then
  local_env+=(SHARED_ARTIFACT_DIR="$shared_artifact_dir")
fi

env "${local_env[@]}" /bin/bash -lc "$builder_script"
