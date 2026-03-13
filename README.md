# Nikarh Arch Repo: Nightly Prebuilt AUR + Custom Packages

## 1) This repository

This repository publishes nightly prebuilt Arch packages that I personally use.

It includes:
- Selected AUR packages
- Custom local packages from `packages/`
- Build targets for `x86_64` and `aarch64` (with per-package arch rules)

Artifacts are published to GitHub Releases under:
- `repo-x86_64`
- `repo-aarch64`

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

## 2) Build your own prebuilt package repo from this template

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
      "id": "lsix",
      "type": "aur",
      "aur": "lsix",
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

### Local verification

Run a local smoke test:

```bash
chmod +x scripts/*.sh
scripts/local-ci-test.sh
```

### License

This project is licensed under GNU GPL v3.0. See [LICENSE](./LICENSE).
