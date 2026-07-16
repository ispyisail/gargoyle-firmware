#!/bin/sh
# make-index.sh -- join a flat asset-record array (see gather-local-assets.sh
# or the gh-api gatherer step in publish-site.yml) against devices/*.json and
# emit index.json: one entry per board, each carrying its release history.
# This is the sole data source for the Finder site (site/app.js) -- same
# script runs identically in local testing and in CI, only the gatherer that
# produces assets.json differs.
#
# Firmware filename convention assumed (OpenWrt sysupgrade/factory naming):
#   openwrt-<target>-<subtarget>-<vendor>_<device>-squashfs-<sysupgrade|factory[-variant]>.<ext>
# The board_name (vendor_device) is exactly OpenWrt's own board_name key, so
# it matches devices/<board_name>.json and the RFC #62 OTA manifest's keys.
#
# Usage: make-index.sh <assets.json> <devices-dir> > index.json
# Assets whose filename doesn't parse, or whose board has no devices/*.json
# entry, still appear (grouped by the parsed board_name) -- unmatched boards
# are called out in the top-level "unknown_boards" list so CI can lint for
# a missing devices/ file instead of silently shipping an unlabeled device.
set -e

assets="$1"
devices_dir="$2"

if [ -z "$assets" ] || [ -z "$devices_dir" ] || [ ! -f "$assets" ] || [ ! -d "$devices_dir" ]; then
	echo "usage: $0 <assets.json> <devices-dir>" >&2
	exit 1
fi

# Merge every devices/*.json into one array up front. Checked explicitly
# (rather than just trying the glob and falling back on failure) because jq
# -s still writes "[]" to stdout even when it can't open the given path --
# on a shell that leaves an unmatched glob as a literal word, that combines
# with a naive `|| echo '[]'` fallback to emit "[]\n[]" (two concatenated
# JSON values), which the --argjson below then rejects as invalid JSON.
set -- "$devices_dir"/*.json
if [ -e "$1" ]; then
	devices_json=$(jq -s '.' "$devices_dir"/*.json)
else
	devices_json='[]'
fi

generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -n \
	--argjson devices "$devices_json" \
	--argjson assets "$(cat "$assets")" \
	--arg generated "$generated" \
'
# board_name -> device metadata, plus every legacy_board_names alias pointing
# at the same object so an old filename still resolves to current metadata.
def device_index:
	reduce $devices[] as $d ({};
		.[$d.board_name] = $d
		| reduce ($d.legacy_board_names // [])[] as $lb (.; .[$lb] = $d)
	);

# Parse one OpenWrt firmware filename into its parts. Returns null (not an
# error) on no match, so callers can skip non-firmware assets cleanly.
def parse_filename:
	capture("^openwrt-(?<target>[a-z0-9]+)-(?<subtarget>[a-z0-9]+)-(?<board>.+)-squashfs-(?<imgtype>sysupgrade|factory(-[a-z]+)?)\\.(?<ext>bin|img|itb)$")?;

($assets
	| map(. + {parsed: (.filename | parse_filename)})
	| map(select(.parsed != null))
) as $parsed
|
(device_index) as $devidx
|
# Group parsed assets by board_name, then by version+channel within a board.
($parsed | group_by(.parsed.board) | map({
	board_name: .[0].parsed.board,
	target: (.[0].parsed.target + "/" + .[0].parsed.subtarget),
	_rows: .
})) as $by_board
|
{
	generated: $generated,
	entries: [
		$by_board[] | . as $b |
		($devidx[$b.board_name]) as $dev |
		{
			board_name: $b.board_name,
			display_name: ($dev.display_name // $b.board_name),
			aliases: ($dev.aliases // []),
			target: $b.target,
			arch: ($dev.arch // null),
			eol: ($dev.eol // false),
			final_version: ($dev.final_version // null),
			note: ($dev.note // null),
			min_ram_kb: ($dev.min_ram_kb // null),
			min_flash_kb: ($dev.min_flash_kb // null),
			known_device: ($dev != null),
			fingerprints: ($dev.fingerprints // null),
			upgradable_from: ($dev.upgradable_from // null),
			releases: [
				($b._rows | group_by(.tag) | map({
					version: (.[0].tag | ltrimstr("v")),
					tag: .[0].tag,
					channel: .[0].channel,
					date: .[0].date,
					images: [ .[] | {
						type: .parsed.imgtype,
						filename: .filename,
						url: .url,
						sha256: .sha256,
						size: .size
					} ]
				}))[]
			] | sort_by(.date) | reverse
		}
	] | sort_by(.display_name),
	unknown_boards: [ $by_board[] | select($devidx[.board_name] == null) | .board_name ] | unique
}
'
