# Archlinux Repository hosted in Github Releases

This is an Archlinux Repository hosted with Github Releases, that contains pre-built AUR and custom packages I personally use that are re-built nightly with Github Actions CI.

It includes:
- Selected AUR packages
- Custom local packages from `packages/`
- Build targets for `x86_64` and `aarch64` (with per-package arch rules)

Artifacts are published to GitHub Releases under:
- `repo-x86_64`
- `repo-aarch64`

## This repository

This repository publishes nightly prebuilt Arch packages that I personally use.
To use this repo from `pacman`, add this to `/etc/pacman.conf`:

```ini
[nikarh]
SigLevel = Optional TrustAll
Server = https://github.com/nikarh/arch-repo/releases/download/repo-$arch
```

Pacman will then fetch:
- `nikarh.db`
- `nikarh.files`
- package files referenced in the db

## Use it as a template to have your own Archlinux Repository

1. Fork or clone this repository.
2. Edit `packages.json`.
3. Replace/remove example custom packages in `packages/`.
4. Enable GitHub Actions in your repo.
5. Run the workflow manually once (`Build and Publish Pacman Repo`).
6. Add your own repo URL in `pacman.conf`.

For faster checks, manual workflow runs support an optional `package` input.
Set it to a package `.id` or `.aur` name from `packages.json` to build only that package.

### `packages.json` structure

```json
{
  "repo": {
    "name": "your-repo-name",
    "prebuild_skip_existing_version": true,
    "same_version_rebuild_policy": "warn_skip_upload"
  },
  "packages": [
    {
      "id": "broadcom-bt-firmware",
      "type": "aur",
      "aur": "broadcom-bt-firmware",
      "arches": ["x86_64", "aarch64"]
    },
    {
      "id": "openscad-git",
      "type": "aur",
      "aur": "openscad-git",
      "arches": ["x86_64"],
      "prebuild_skip_existing_version": false,
      "same_version_rebuild_policy": "force_upload"
    }
  ]
}
```

Field notes:
- `repo.name`: pacman repo name (`<name>.db`, `<name>.files`)
- `repo.prebuild_skip_existing_version` (default `true`):
  - If release `repo-$arch` already has assets for the resolved package version, skip rebuilding that package.
- `repo.same_version_rebuild_policy` (global, default `warn_skip_upload`):
  - `warn_skip_upload`: if a rebuild produced same `pkgver-pkgrel` but different hash, warn and do not upload.
  - `force_upload` is intentionally not supported globally.
- `packages[].type`:
  - `aur`: clone from AUR using `aur`
  - `local`: build from local folder using `path`
- `packages[].arches`: per-package arch control
- `packages[].prebuild_skip_existing_version` (optional): per-package override for pre-build skip behavior
- `packages[].same_version_rebuild_policy` (optional):
  - `warn_skip_upload`: warn and skip upload when same version hash changes
  - `force_upload`: force replace package even when version is unchanged
- If a package PKGBUILD declares `validpgpkeys`, build automatically tries to import those keys before source verification.
- If a package is listed for an arch but PKGBUILD does not support that arch, it is skipped with a warning for that arch build.

Behavior summary:
- Default behavior (`prebuild_skip_existing_version: true`): no unnecessary rebuilds if same-version asset already exists in release.
- Variant 2: set `prebuild_skip_existing_version: false`, keep `same_version_rebuild_policy: warn_skip_upload`.
- Variant 3: same as Variant 2, but set package override `same_version_rebuild_policy: force_upload`.

### Custom package layout

Each local package should have at least:
- `packages/<pkg>/PKGBUILD`
- any files referenced by that PKGBUILD

### Optional signing

If you want signed repo metadata, add these repo secrets:
- `PACMAN_GPG_PRIVATE_KEY_B64`
- `PACMAN_GPG_KEY_ID`
- `PACMAN_GPG_PASSPHRASE` (optional)

### GPG key generation and export

Generate a dedicated key for repo signing:

```bash
gpg --full-generate-key
```

Recommended choices:
- key type: `RSA and RSA`
- key size: `4096`
- expiration: your preference
- user ID: something like `Pacman Repo Signing <you@example.com>`

Get the key ID (long format):

```bash
gpg --list-secret-keys --keyid-format=long
```

Export secret key in base64 form for GitHub Secrets:

```bash
gpg --export-secret-keys --armor <KEY_ID> | base64 -w0
```

If your `base64` does not support `-w0`:

```bash
gpg --export-secret-keys --armor <KEY_ID> | base64 | tr -d '\n'
```

Set these repository secrets:
- `PACMAN_GPG_PRIVATE_KEY_B64`: output of the export command above
- `PACMAN_GPG_KEY_ID`: your key ID (example: `ABCDEF1234567890`)
- `PACMAN_GPG_PASSPHRASE`: passphrase used for the key (omit only if key has no passphrase)

### Local verification

Run a local smoke test:

```bash
chmod +x scripts/*.sh
scripts/local-ci-test.sh
```

Run local smoke test for one package only:

```bash
scripts/local-ci-test.sh ./.tmp/test-build yay
```

Retry tuning (local and CI):

```bash
BUILD_RETRY_COUNT=3 BUILD_RETRY_DELAY_SEC=20 scripts/local-ci-test.sh
```

### License

This project is licensed under GNU GPL v3.0. See [LICENSE](./LICENSE).
