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

resolve_aur_deps() {
  local srcinfo dep_line dep_name dep_lookup
  local -a dep_names=()
  local -a aur_deps=()

  srcinfo="$(sudo -u "$build_user" makepkg --printsrcinfo)"
  while IFS= read -r dep_line; do
    dep_line="${dep_line#"${dep_line%%[![:space:]]*}"}"
    case "$dep_line" in
      "depends = "*|"makedepends = "*|"checkdepends = "*)
        dep_name="${dep_line#*= }"
        dep_name="${dep_name%%[<>=]*}"
        dep_name="${dep_name//[[:space:]]/}"
        [[ -z "$dep_name" ]] && continue
        # Soname/path style deps are not package names.
        [[ "$dep_name" == *".so"* || "$dep_name" == */* ]] && continue
        dep_names+=("$dep_name")
        ;;
    esac
  done <<< "$srcinfo"

  if [[ ${#dep_names[@]} -eq 0 ]]; then
    return 0
  fi

  mapfile -t dep_names < <(printf '%s\n' "${dep_names[@]}" | sort -u)
  for dep_lookup in "${dep_names[@]}"; do
    if pacman -Si "$dep_lookup" >/dev/null 2>&1 || pacman -Q "$dep_lookup" >/dev/null 2>&1; then
      continue
    fi
    if curl -fsSL "https://aur.archlinux.org/rpc/?v=5&type=info&arg[]=${dep_lookup}" | jq -e '.resultcount > 0' >/dev/null 2>&1; then
      aur_deps+=("$dep_lookup")
    fi
  done

  if [[ ${#aur_deps[@]} -eq 0 ]]; then
    return 0
  fi

  install_yay
  sudo -u "$build_user" yay -S --noconfirm --needed --asdeps \
    --mflags "--noconfirm --needed --skippgpcheck" \
    --answerclean None \
    --answerdiff None \
    "${aur_deps[@]}"
}

if [[ "$MODE" == "list" ]]; then
  sudo -u "$build_user" "${makepkg_cmd[@]}" --packagelist | sed 's#^.*/##'
  exit 0
fi

if [[ "${ENABLE_AUR_DEPS:-1}" == "1" ]]; then
  resolve_aur_deps
fi

sudo -u "$build_user" "${makepkg_cmd[@]}" --syncdeps --noconfirm --clean --cleanbuild --needed --noprogressbar --skippgpcheck

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

if [[ "$mode" == "list" ]]; then
  (
    cd "$src_dir"
    "${makepkg_cmd[@]}" --packagelist
  ) | sed 's#^.*/##'
  exit 0
fi

if [[ "${ENABLE_AUR_DEPS:-1}" == "1" ]]; then
  srcinfo="$(bash -lc "cd '$src_dir' && makepkg --printsrcinfo")"
  mapfile -t dep_names < <(
    while IFS= read -r dep_line; do
      dep_line="${dep_line#"${dep_line%%[![:space:]]*}"}"
      case "$dep_line" in
        "depends = "*|"makedepends = "*|"checkdepends = "*)
          dep_name="${dep_line#*= }"
          dep_name="${dep_name%%[<>=]*}"
          dep_name="${dep_name//[[:space:]]/}"
          [[ -z "$dep_name" ]] && continue
          [[ "$dep_name" == *".so"* || "$dep_name" == */* ]] && continue
          echo "$dep_name"
          ;;
      esac
    done <<< "$srcinfo" | sort -u
  )

  aur_deps=()
  for dep_lookup in "${dep_names[@]}"; do
    if pacman -Si "$dep_lookup" >/dev/null 2>&1 || pacman -Q "$dep_lookup" >/dev/null 2>&1; then
      continue
    fi
    if curl -fsSL "https://aur.archlinux.org/rpc/?v=5&type=info&arg[]=${dep_lookup}" | jq -e '.resultcount > 0' >/dev/null 2>&1; then
      aur_deps+=("$dep_lookup")
    fi
  done

  if [[ ${#aur_deps[@]} -gt 0 ]]; then
    if ! command -v yay >/dev/null 2>&1; then
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
    fi
    yay -S --noconfirm --needed --asdeps \
      --mflags "--noconfirm --needed --skippgpcheck" \
      --answerclean None \
      --answerdiff None \
      "${aur_deps[@]}"
  fi
fi

(
  cd "$src_dir"
  "${makepkg_cmd[@]}" --syncdeps --noconfirm --clean --cleanbuild --needed --noprogressbar --skippgpcheck
)

shopt -s nullglob
for f in "$src_dir"/*.pkg.tar.zst "$src_dir"/*.pkg.tar.xz "$src_dir"/*.pkg.tar.gz "$src_dir"/*.pkg.tar.bz2; do
  cp -v "$f" "$out_dir/"
done
for sig in "$src_dir"/*.pkg.tar.zst.sig "$src_dir"/*.pkg.tar.xz.sig "$src_dir"/*.pkg.tar.gz.sig "$src_dir"/*.pkg.tar.bz2.sig; do
  cp -v "$sig" "$out_dir/"
done
