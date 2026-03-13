# arc-poc: GitHub Actions Pacman Repo POC

This repository builds AUR packages and inlined PKGBUILD packages, then publishes prebuilt artifacts and pacman repo metadata into GitHub Releases.

## What it does

- Builds packages nightly and on manual trigger (`workflow_dispatch`).
- Supports AUR packages and local package folders with `PKGBUILD` and files.
- Builds for `x86_64` and `aarch64` by default.
- Allows per-package arch constraints in `packages.json`.
- Publishes packages and repo db/files to release tags:
  - `repo-x86_64`
  - `repo-aarch64`
- Guards against pointless updates:
  - If version and SHA256 are unchanged, package upload is skipped.
  - If version is unchanged but SHA256 differs, build fails by default (`same_version_policy: fail`), configurable to `warn`.

## Layout

- `packages.json`: package definitions + repo settings.
- `packages/<name>/`: local package sources (`PKGBUILD` and files).
- `scripts/build-packages.sh`: builds configured packages for one architecture.
- `scripts/publish-release.sh`: updates release-backed pacman repo assets.
- `.github/workflows/build-and-release.yml`: CI/CD pipeline.

## Config format (`packages.json`)

```json
{
  "repo": {
    "name": "arc-poc",
    "same_version_policy": "fail"
  },
  "packages": [
    {
      "id": "lsix",
      "type": "aur",
      "aur": "lsix",
      "arches": ["x86_64", "aarch64"]
    },
    {
      "id": "hello-text",
      "type": "local",
      "path": "packages/hello-text",
      "arches": ["x86_64"]
    }
  ]
}
```

`arches` controls per-package arch routing.

## pacman.conf setup

Choose arch-specific server URLs:

```ini
[arc-poc]
SigLevel = Optional TrustAll
Server = https://github.com/<OWNER>/<REPO>/releases/download/repo-$arch
```

With `repo.name = "arc-poc"`, pacman fetches:

- `arc-poc.db`
- `arc-poc.files`
- package files listed in db

All are served from the same release tag path, so GH Pages is not required.

## Optional signing

If you provide these repository secrets, db/files are signed:

- `PACMAN_GPG_PRIVATE_KEY_B64`
- `PACMAN_GPG_KEY_ID`
- `PACMAN_GPG_PASSPHRASE` (optional)

## Local test

Run an x86_64 test build locally:

```bash
chmod +x scripts/*.sh
scripts/local-ci-test.sh
```

This POC includes:

- AUR package: `lsix`
- Local package: `hello-text` (installs one text file)
