# gargoyle-firmware

Hosting and discovery for Gargoyle firmware images and (from Phase 2) plugin
packages: a searchable **Firmware Finder** served from GitHub Pages, backed
by GitHub Releases for the actual binaries.

Full project scope: [RFC discussion #99](https://github.com/ispyisail/gargoyle/discussions/99)
and `docs/firmware-hosting-plan.md` in `gargoyle-tools`. This RFC is also
RFC #62's (signed OTA upgrade) Rung-2 Firmware Finder.

## What's here (Phase 1)

- **`site/`** — the Finder itself. Static HTML/CSS/vanilla JS, no build
  step, no external dependencies. Fetches `index.json` (generated, not
  committed) and provides client-side search/filter by device model, alias,
  target, or release channel.
- **`devices/`** — one JSON file per board: display name, search aliases,
  hardware floors, EOL status, legacy board-name history. See
  `devices/README.md` for the schema. This is hand-maintained, reviewable
  data — adding a device or marking one EOL is a small PR here, not a script
  change.
- **`scripts/make-index.sh`** — joins a flat asset-record list against
  `devices/*.json` and emits `index.json`, grouped by board with full
  release history. Same script runs in CI and in local testing.
- **`scripts/gather-local-assets.sh`** — walks a local staging directory
  (`<channel>/<tag>/<filename>`) to produce that asset-record list, for
  testing the Finder without any real GitHub release existing yet.
- **`scripts/gather-github-assets.sh`** — the production gatherer: walks
  real GitHub Releases via `gh api`, resolving each image's sha256 from a
  `.sha256` sidecar asset (never by downloading the image itself).
- **`.github/workflows/publish-site.yml`** — regenerates `index.json` and
  deploys `site/` to Pages whenever a release is published, `devices/`
  metadata changes, or on manual dispatch.

## Not yet in scope

- **Plugin feeds** (Phase 2) — per-arch `Packages.gz` indexes, and the
  firmware-side change to point `opkg.conf`'s default source at them.
- **Firmware builds** (Phase 3) — `build-release.yml`, matrix builds,
  self-hosted runner for heavy targets, image signing.
- **OTA manifest generation** (Phase 4) — `scripts/make-manifest.sh`
  producing RFC #62's signed `manifest-{stable,testing}.json` from this same
  `devices/` data (floors, EOL, `history`, `upgradable_from`).

## Local testing

No live repo or release needed:

```sh
# 1. Stage a fake release tree: <channel>/<tag>/<firmware-filename>
mkdir -p staging/stable/v1.16.0
cp some-openwrt-image.bin staging/stable/v1.16.0/

# 2. Gather -> index -> serve
sh scripts/gather-local-assets.sh staging > assets.json
sh scripts/make-index.sh assets.json devices > site/index.json
cd site && python3 -m http.server 8000
# open http://127.0.0.1:8000/
```

Firmware filenames must follow the OpenWrt sysupgrade/factory naming
convention (`openwrt-<target>-<subtarget>-<board_name>-squashfs-<sysupgrade|factory[-variant]>.<ext>`)
for `make-index.sh` to parse them; anything else is skipped rather than
crashing the build.
