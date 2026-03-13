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

### `packages.json` structure

```json
{
  "repo": {
    "name": "your-repo-name",
    "same_version_policy": "fail"
  },
  "packages": [
    {
      "id": "broadcom-bt-firmware",
      "type": "aur",
      "aur": "broadcom-bt-firmware",
      "arches": ["x86_64", "aarch64"]
    },
    {
      "id": "my-custom-package",
      "type": "local",
      "path": "packages/my-custom-package",
      "arches": ["x86_64"]
    }
  ]
}
```

Field notes:
- `repo.name`: pacman repo name (`<name>.db`, `<name>.files`)
- `repo.same_version_policy`:
  - `fail`: stop if version stayed same but content changed
  - `warn`: continue but print warning
- `packages[].type`:
  - `aur`: clone from AUR using `aur`
  - `local`: build from local folder using `path`
- `packages[].arches`: per-package arch control

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

### License

This project is licensed under GNU GPL v3.0. See [LICENSE](./LICENSE).
