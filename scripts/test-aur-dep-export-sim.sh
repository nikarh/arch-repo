#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

pkg_root="$tmp_root/rootpkg"
sim_root="$tmp_root/sim"
out_root="$tmp_root/out"
config_file="$tmp_root/packages.json"
config_with_explicit_dep="$tmp_root/packages-with-explicit-dep.json"

mkdir -p "$pkg_root/.codex-artifacts" "$sim_root/dep-a/artifacts" "$sim_root/dep-b/artifacts" "$out_root"

cat > "$config_file" <<JSON
{
  "repo": {
    "default_arches": ["x86_64"]
  },
  "packages": [
    {
      "type": "local",
      "id": "rootpkg",
      "path": "$pkg_root"
    }
  ]
}
JSON

cat > "$pkg_root/.codex-srcinfo" <<'EOF_SRCINFO'
pkgbase = rootpkg
  pkgname = rootpkg
  depends = dep-b
EOF_SRCINFO

cat > "$pkg_root/.codex-packagelist" <<'EOF_PACKAGES'
rootpkg-1-1-any.pkg.tar.zst
EOF_PACKAGES

touch "$pkg_root/.codex-artifacts/rootpkg-1-1-any.pkg.tar.zst"

mkdir -p "$sim_root/dep-a" "$sim_root/dep-b"

cat > "$sim_root/dep-a/srcinfo" <<'EOF_SRCINFO'
pkgbase = dep-a
  pkgname = dep-a
EOF_SRCINFO

cat > "$sim_root/dep-a/packagelist.txt" <<'EOF_PACKAGES'
dep-a-1-1-any.pkg.tar.zst
EOF_PACKAGES

touch "$sim_root/dep-a/artifacts/dep-a-1-1-any.pkg.tar.zst"

cat > "$sim_root/dep-b/srcinfo" <<'EOF_SRCINFO'
pkgbase = dep-b
  pkgname = dep-b
  depends = dep-a
EOF_SRCINFO

cat > "$sim_root/dep-b/packagelist.txt" <<'EOF_PACKAGES'
dep-b-1-1-any.pkg.tar.zst
EOF_PACKAGES

touch "$sim_root/dep-b/artifacts/dep-b-1-1-any.pkg.tar.zst"

(
  cd "$repo_root"
  MAKEPKG_DOCKER_SIM_ROOT="$sim_root" \
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

echo "simulation ok"

cat > "$config_with_explicit_dep" <<JSON
{
  "repo": {
    "default_arches": ["x86_64"]
  },
  "packages": [
    {
      "type": "local",
      "id": "rootpkg",
      "path": "$pkg_root"
    },
    {
      "type": "local",
      "id": "dep-b",
      "path": "$pkg_root"
    }
  ]
}
JSON

dup_out_root="$tmp_root/out-dup"
dup_log="$tmp_root/dup.log"

(
  cd "$repo_root"
  MAKEPKG_DOCKER_SIM_ROOT="$sim_root" \
  PACKAGES_CONFIG_FILE="$config_with_explicit_dep" \
  scripts/build-packages.sh x86_64 "$dup_out_root" "rootpkg,dep-b"
) | tee "$dup_log"

grep -F "SKIP BUILD: dep-b already has version assets in repo-x86_64" "$dup_log" >/dev/null

echo "dedupe ok"
