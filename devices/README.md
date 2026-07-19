# devices/ — per-board metadata

One JSON file per board. The **filename** is a filesystem-friendly slug
(same underscore form as the build's `DEVICE_NAME`/image-filename board
token, e.g. `glinet_gl-mt6000.json`) — it is just a stable identifier for
this directory and is never read by the scripts. The **`board_name` field
inside the file** is a different thing and must be the real runtime OpenWrt
`board_name` (`ubus call system board | jsonfilter -e '@.board_name'` on the
actual device, or `fwtool -i - image.bin` on the built image) — this is the
comma-separated `vendor,model` form (e.g. `glinet,gl-mt6000`), and it is the
exact key `make-manifest.sh` writes into the OTA manifest and the exact
string a router's OTA client compares against with a plain string-equality
check (no normalization, no fallback to aliases). Filename slug and
`board_name` field looking similar is a coincidence of convention, not a
constraint — getting this field wrong silently breaks OTA for that device
with no error anywhere, since `not-listed` is also the correct response for
a genuinely unsupported board. This is the single source of truth that
`make-index.sh` and `make-manifest.sh` both join against, so marking a device
EOL or fixing an alias is a one-file PR, not a script edit.

## Schema

```json
{
  "board_name": "glinet,gl-mt6000",
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

- `board_name` — the real runtime OpenWrt board key, comma-separated
  `vendor,model` form (e.g. `glinet,gl-mt6000`), **not** the underscore
  build/filename slug (`glinet_gl-mt6000`) — the two look similar but are
  different values. Verify against a real device (`ubus call system board`)
  or, failing that, the built image (`fwtool -i - image.bin` ->
  `supported_devices[0]`) before trusting a guess.
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
