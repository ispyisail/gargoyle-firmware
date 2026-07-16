# devices/ — per-board metadata

One JSON file per board, named `<board_name>.json` (the OpenWrt `board_name`,
e.g. `ubus call system board | jsonfilter -e '@.board_name'` — same key the
OTA manifest in RFC #62 uses). This is the single source of truth that
`make-index.sh` and `make-manifest.sh` both join against, so marking a device
EOL or fixing an alias is a one-file PR, not a script edit.

## Schema

```json
{
  "board_name": "glinet_gl-mt6000",
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

- `board_name` — canonical OpenWrt board key; must match the value baked
  into the image (`fwtool -i - image.bin` -> `board_name`).
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
