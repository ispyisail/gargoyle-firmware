# gargoyle-firmware

Hosting and discovery for Gargoyle firmware images and (from Phase 2) plugin
packages: a searchable **Firmware Finder** served from GitHub Pages, backed
by GitHub Releases for the actual binaries.

Full project scope: [RFC discussion #99](https://github.com/ispyisail/gargoyle/discussions/99)
and `docs/firmware-hosting-plan.md` in `gargoyle-tools`. This RFC is also
RFC #62's (signed OTA upgrade) Rung-2 Firmware Finder.

## What's here

**Phase 1 — Firmware Finder:**

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

**Phase 2 — plugin feed:**

- **`scripts/make-feed.sh`** — builds an opkg `Packages`/`Packages.gz` feed
  index for each `plugins-<major>-<arch>` release. Downloads every `.ipk` in
  that release directly (plugins are small enough that this is cheap and
  gives real control-file fields — Depends, Provides, Description — rather
  than guessing from the filename) and hashes/sizes the actual bytes.
  **Important, verified against opkg's own source**
  (`libopkg/opkg_download.c`): opkg resolves *both* the package list and
  every package's `Filename:` by concatenating them onto the same `src/gz
  <name> <url>` base — there is no absolute-URL case. The generated
  `Packages`/`Packages.gz` must therefore be uploaded into the **same
  release** as the `.ipk`s it describes, not hosted on Pages; the firmware's
  default `src/gz gargoyle_core <url>` line points directly at that
  release's own download base.
- **`scripts/parse-control.awk`** — parses a real Debian/opkg control file
  (an `.ipk` is a plain gzipped tar containing `./debian-binary`,
  `./data.tar.gz`, `./control.tar.gz` — confirmed against real Gargoyle
  builds, not assumed from the `.deb`/`ar` format) into key/value records,
  correctly handling multi-line values like `Description` (verified
  byte-for-byte against a real OpenWrt-generated `Packages` index, including
  its exact whitespace conventions).

**Phase 3 — firmware builds:**

- **`.github/workflows/build-release.yml`** — builds real firmware for one
  or more targets on the self-hosted runner, signs every sysupgrade image
  with the OTA usign key as a **detached `.sig` sidecar** (never appended:
  the build already appends its own ucert signature block via `BUILD_KEY`,
  and stacking a second trailer in that slot would break stock sysupgrade
  signature checking the day it is enforced — published bytes stay
  identical to what the build produced), uploads images + `.sig` +
  `.sha256` sidecars to a GitHub Release
  (created as a draft and published only after every asset is in place, so
  the `release: published` event never fires against an empty release), and
  lets that event cascade into `publish-site.yml` and `sign-manifests.yml`.
- **`scripts/generate-ota-key.sh`** — one-time keypair generation on the
  build host. The private key never leaves that machine and is never stored
  as a GitHub secret.
- **`scripts/verify-image.sh`** — verify a downloaded image the way a
  router would (optional sha256, then `usign -V` against `ota.pub`).
- **`.github/workflows/runner-smoke-test.yml`** — cheap sanity check that
  the self-hosted runner has the env vars, key, Docker access, and workspace
  `build-release.yml` depends on.

**Phase 4 — OTA manifests (RFC #62):**

- **`scripts/make-manifest.sh`** — emits `manifest-{stable,testing}.json`:
  one entry per `board_name`, pointing at the newest sysupgrade image that
  channel offers, joined against `devices/*.json` for hardware floors and
  EOL pinning. Fail-closed: boards with unmeasured floors, images without a
  sha256 sidecar, or EOL boards without a `final_version` are skipped loudly
  rather than guessed at.
- **`.github/workflows/sign-manifests.yml`** — regenerates both manifests,
  signs them with the OTA key on the self-hosted runner, verifies the
  signatures against the public key before anything ships, commits the
  result under `site/ota/`, and dispatches the Pages deploy. Routers fetch
  `site/ota/manifest-<channel>.json` + `.sig` and verify against the
  `ota.pub` baked into their image.

- **`site/identify.js`** — the Finder's backup-tarball device identifier
  (RFC #62 Rung 2): drag a Gargoyle backup onto the page and it matches the
  wireless config's radio paths against `devices/*.json` fingerprints,
  entirely client-side. Returns ranked candidates (radio paths are shared
  within SoC families), plus a firmware-era estimate that drives the right
  upgrade-route instruction.

## Not yet in scope

- The **on-router OTA client** (`ota_upgrade.sh` + UI page) — RFC #62's
  router-side half, which consumes the manifests published here. Lives in
  the main gargoyle repo when it lands.

## A portability note for anyone editing these scripts

Every script here targets `/bin/sh`, and on the runners and containers this
project actually runs on, `/bin/sh` is **dash** — whose builtin `echo`
interprets backslash escapes by default (unlike bash's). Piping a variable
that might contain a literal backslash sequence through `echo "$var" | ...`
can silently corrupt it (a real, previously-shipped bug: an escaped `\n`
inside a JSON-serialized string was turned into an actual newline byte,
breaking the next `jq` stage). Always use `printf '%s\n' "$var"` instead of
`echo "$var"` when the value came from anywhere other than a string literal
you wrote yourself.

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
