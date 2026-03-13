#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <arch> <src_dir> <out_dir>" >&2
  exit 1
fi

arch="$1"
src_dir="$(realpath "$2")"
out_dir="$(realpath "$3")"

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

mkdir -p "$out_dir"

container_script=$(cat <<'EOS'
set -euo pipefail
export HOME=/root
pacman -Syu --noconfirm --needed archlinux-keyring >/dev/null
pacman -S --noconfirm --needed base-devel git sudo >/dev/null

if ! id -u builder >/dev/null 2>&1; then
  useradd -m builder
fi
echo 'builder ALL=(ALL) NOPASSWD: /usr/bin/pacman' > /etc/sudoers.d/builder-pacman
chmod 0440 /etc/sudoers.d/builder-pacman

chown -R builder:builder /src /out
cd /src

sudo -u builder makepkg --syncdeps --noconfirm --clean --cleanbuild --needed --noprogressbar

shopt -s nullglob
for f in ./*.pkg.tar.zst ./*.pkg.tar.xz ./*.pkg.tar.gz ./*.pkg.tar.bz2; do
  cp -v "$f" /out/
done
for sig in ./*.pkg.tar.zst.sig ./*.pkg.tar.xz.sig ./*.pkg.tar.gz.sig ./*.pkg.tar.bz2.sig; do
  cp -v "$sig" /out/
done
EOS
)

if command -v docker >/dev/null 2>&1; then
  docker run --rm \
    --platform "$docker_platform" \
    -v "$src_dir:/src" \
    -v "$out_dir:/out" \
    "$docker_image" \
    /bin/bash -lc "$container_script"
  # Builder user inside the container may have altered ownership on host-mounted paths.
  chown -R "$(id -u)":"$(id -g)" "$src_dir" "$out_dir" || true
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

sudo pacman -Syu --noconfirm --needed archlinux-keyring base-devel git sudo >/dev/null

bash -lc "cd '$src_dir' && makepkg --syncdeps --noconfirm --clean --cleanbuild --needed --noprogressbar"

shopt -s nullglob
for f in "$src_dir"/*.pkg.tar.zst "$src_dir"/*.pkg.tar.xz "$src_dir"/*.pkg.tar.gz "$src_dir"/*.pkg.tar.bz2; do
  cp -v "$f" "$out_dir/"
done
for sig in "$src_dir"/*.pkg.tar.zst.sig "$src_dir"/*.pkg.tar.xz.sig "$src_dir"/*.pkg.tar.gz.sig "$src_dir"/*.pkg.tar.bz2.sig; do
  cp -v "$sig" "$out_dir/"
done
