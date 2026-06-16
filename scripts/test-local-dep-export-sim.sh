#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

dep_a_root="$tmp_root/dep-a"
dep_b_root="$tmp_root/dep-b"
pkg_root="$tmp_root/rootpkg"
out_root="$tmp_root/out"
config_file="$tmp_root/packages.json"

mkdir -p \
  "$dep_a_root/.codex-artifacts" \
  "$dep_b_root/.codex-artifacts" \
  "$pkg_root/.codex-artifacts" \
  "$out_root"

cat > "$config_file" <<JSON
{
  "repo": {
    "default_arches": ["x86_64"]
  },
  "packages": [
    {
      "id": "dep-a",
      "path": "$dep_a_root"
    },
    {
      "id": "dep-b",
      "path": "$dep_b_root"
    },
    {
      "id": "rootpkg",
      "path": "$pkg_root"
    }
  ]
}
JSON

cat > "$dep_a_root/.codex-srcinfo" <<'EOF_SRCINFO'
pkgbase = dep-a
  pkgname = dep-a
EOF_SRCINFO

cat > "$dep_a_root/.codex-packagelist" <<'EOF_PACKAGES'
dep-a-1-1-any.pkg.tar.zst
EOF_PACKAGES

touch "$dep_a_root/.codex-artifacts/dep-a-1-1-any.pkg.tar.zst"

cat > "$dep_b_root/.codex-srcinfo" <<'EOF_SRCINFO'
pkgbase = dep-b
  pkgname = dep-b
  depends = dep-a
EOF_SRCINFO

cat > "$dep_b_root/.codex-packagelist" <<'EOF_PACKAGES'
dep-b-1-1-any.pkg.tar.zst
EOF_PACKAGES

touch "$dep_b_root/.codex-artifacts/dep-b-1-1-any.pkg.tar.zst"

cat > "$pkg_root/.codex-srcinfo" <<'EOF_SRCINFO'
pkgbase = rootpkg
  pkgname = rootpkg
  depends = dep-b
EOF_SRCINFO

cat > "$pkg_root/.codex-packagelist" <<'EOF_PACKAGES'
rootpkg-1-1-any.pkg.tar.zst
EOF_PACKAGES

touch "$pkg_root/.codex-artifacts/rootpkg-1-1-any.pkg.tar.zst"

(
  cd "$repo_root"
  MAKEPKG_DOCKER_SIM_ROOT="$tmp_root/sim" \
  PACKAGES_CONFIG_FILE="$config_file" \
  scripts/build-packages.sh x86_64 "$out_root" rootpkg
)

for expected in \
  "$out_root/dep-a-1-1-any.pkg.tar.zst" \
  "$out_root/dep-b-1-1-any.pkg.tar.zst" \
  "$out_root/rootpkg-1-1-any.pkg.tar.zst"; do
  [[ -f "$expected" ]] || {
    echo "missing expected artifact: $expected" >&2
    exit 1
  }
done

jq -e '
  map(.filename) | sort == [
    "dep-a-1-1-any.pkg.tar.zst",
    "dep-b-1-1-any.pkg.tar.zst",
    "rootpkg-1-1-any.pkg.tar.zst"
  ]
' "$out_root/manifest.json" >/dev/null

jq -e '
  map(.id) | sort == [
    "dep-a",
    "dep-b",
    "rootpkg"
  ]
' "$out_root/manifest.json" >/dev/null

echo "local dependency simulation ok"
