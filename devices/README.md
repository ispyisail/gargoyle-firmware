# devices/ — per-board metadata

One JSON file per board, named `<board_name>.json`. This is the single
source of truth that `make-index.sh` and `make-manifest.sh` both join
against, so marking a device EOL or fixing an alias is a one-file PR, not a
script edit.

**Two different "board name" concepts live in this file, and they must not
be confused** (a real bug, found live 2026-07-19: every file had
`ota_board_name`'s value incorrectly stored in `board_name`, which broke
`make-manifest.sh`'s and `make-index.sh`'s ability to match this file to
its own release images at all, since 100% of assets stopped resolving):

- `board_name` — the underscore build/filename slug, e.g. `glinet_gl-mt6000`.
  This is what `make-index.sh`/`make-manifest.sh` parse out of release image
  filenames (`openwrt-<target>-<subtarget>-<board_name>-squashfs-...`), so it
  **must** match that filename token exactly or this device's images will
  silently match nothing (no error, no skip warning — the join just finds
  zero candidates).
- `ota_board_name` — the real runtime OpenWrt board key, comma-separated
  `vendor,model` form, e.g. `glinet,gl-mt6000` (`ubus call system board` on
  the device, or `fwtool -i - image.bin` -> `supported_devices[0]` on the
  built image). This is the exact string `make-manifest.sh` writes as the
  OTA manifest's device key, and the exact string a router's OTA client
  compares against with a plain equality check (no normalization, no
  fallback to `aliases`/`legacy_board_names`). A device with no
  `ota_board_name` set never gets an OTA manifest entry (fail-closed) but
  still appears normally in the Finder.

These two values look similar and are easy to conflate, but they come from
different places (build-system slug vs. runtime DTS-derived identity) and
serve different joins — never assume one from the other; verify each
independently before trusting it.

## Schema

```json
{
  "board_name": "glinet_gl-mt6000",
  "ota_board_name": "glinet,gl-mt6000",
  "display_name": "GL.iNet GL-MT6000",
  "aliases": ["mt6000", "gl-mt6000", "gl.inet mt6000"],
  "target": "mediatek/filogic",
  "arch": "aarch64_cortex-a53",
  "min_ram_kb": 131072,
  "min_flash_kb": 32768,
  "eol": false,
  "final_version": null,
  "note": null,
  "legacy_board_names": ["gl-mt6000"],
  "upgradable_from": {
    ">=1.13": "direct",
    "1.10-1.12": "direct-legacy-name",
    "<1.10": "manual-factory"
  }
}
```

Field notes:

- `board_name` — underscore build/filename slug; must match the token in
  this device's release image filenames exactly (see above).
- `ota_board_name` — real runtime OpenWrt board key, comma-separated
  `vendor,model` form (see above). Optional: omit it and the device still
  works everywhere except OTA (no manifest entry is published for it).
- `aliases` — free-text search terms a human would type (marketing names,
  common misspellings). Only used by the Finder's search index, never by
  firmware logic.
- `target` / `arch` — OpenWrt target/subtarget and package architecture.
  `arch` is what selects which plugin feed directory a device's packages
  come from (see `../scripts/make-feed.sh`).
- `min_ram_kb` / `min_flash_kb` — hardware floors (RFC #62). Omit or `null`
  if not yet measured; `make-manifest.sh` should refuse to publish an OTA
  entry for a board with no floor data rather than assume it's fine.
- `eol` / `final_version` / `note` — EOL terminal state (RFC #62 Tier C).
  When `eol: true`, `final_version` is the last image ever offered and
  `note` is shown verbatim to the user.
- `legacy_board_names` — earlier `board_name` values the same physical
  device reported under an older OpenWrt/Gargoyle release (renames happen).
  Lets `make-index.sh` group historical releases under one Finder entry.
- `upgradable_from` — RFC #62 bootstrap Rung-1 routing: which source-version
  ranges can take a direct OTA/manual jump to current vs. need the
  Finder's manual-factory path. Keys are version-range expressions matched
  by `make-index.sh`; values are one of `direct`, `direct-legacy-name`,
  `manual-factory`.
- `fingerprints.wifi_paths` — the `option path` values OpenWrt writes into
  `/etc/config/wireless` for this board, one per radio (a second PHY on the
  same node gets a `+1` suffix). Used by the Finder's backup-tarball
  identifier (RFC #62 Rung 2): a config backup contains no `board_name`, so
  these paths are the strongest board signal it carries. They come from the
  device tree, so boards sharing a SoC family can share values (all ath79
  boards report `platform/ahb/18100000.wmac`) — the identifier therefore
  ranks candidates rather than claiming a unique match. Verify against a
  real device's `/etc/config/wireless` where possible; DTS node addresses in
  `target/linux/<target>/dts/` are the source otherwise.

Every field except `board_name`, `display_name`, `target`, `arch` is
optional — a new board can be added with minimal data and filled in as it's
validated.
