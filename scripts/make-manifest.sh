#!/bin/sh
# make-manifest.sh -- Phase 4: emit the RFC #62 OTA version manifest for one
# channel, joining the same canonical asset-record array the Finder uses
# (gather-github-assets.sh / gather-local-assets.sh) against devices/*.json.
#
# The manifest is what a router's ota_upgrade.sh fetches to answer "is there
# an update for me, and where do I get it" -- one entry per ota_board_name
# (the key `ubus call system board` reports; NOT the same as board_name,
# which is the underscore filename slug used to match this device to its
# own release images -- see devices/README.md), each pointing at exactly ONE
# sysupgrade image: the newest release that channel offers for that board.
# A device with no ota_board_name set is skipped entirely (fail-closed --
# found live 2026-07-19: publishing under the wrong key silently offers an
# update no router can ever match, and there is no error anywhere to catch
# it). Factory images never appear here (OTA applies sysupgrade only;
# factory flashing is the Finder's manual path).
#
# Channel semantics:
#   stable  -> only releases whose tag has no -rc/-beta/-alpha/-testing
#              suffix are considered.
#   testing -> ALL releases are considered, so a testing-channel router is
#              offered a newer stable build too (a stable release supersedes
#              the rc that preceded it -- testing users should not be
#              stranded on an old rc because the fix shipped as stable).
#
# Fail-closed rules (deliberate -- an OTA that guesses is worse than none):
#   - board has no devices/<board>.json        -> skipped, stderr warning
#   - min_ram_kb or min_flash_kb is null       -> skipped, stderr warning
#     (devices/README.md: never publish an OTA entry for a board whose
#     hardware floors haven't been measured)
#   - image has no sha256 (missing sidecar)    -> skipped, stderr warning
#     (the on-router verify step is sha256-then-usign; a null sha256 would
#     turn verification into a no-op)
#   - image has no detached .sig sidecar       -> skipped, stderr warning
#     (signatures are DETACHED, not appended: the build already appends
#     its own ucert block via BUILD_KEY, and stacking a second trailer on
#     that slot would break stock signature checking when enforced)
#   - eol: true with final_version set         -> entry pinned to that
#     version forever, note included verbatim (RFC #62 Tier C); newer
#     releases for the board are ignored
#   - eol: true with no final_version          -> skipped entirely
#
# This script does NOT sign anything. usign lives on the key-holding build
# host (inside the builder container), not on hosted CI, so signing is the
# sign-manifests workflow's job -- generation is kept host-agnostic so it
# can be tested anywhere jq exists.
#
# Output key order is canonicalized (jq -S) so regenerating an unchanged
# manifest is byte-identical except for the "generated" timestamp -- the
# workflow diffs `del(.generated)` to decide whether a commit is warranted.
#
# Usage: make-manifest.sh <assets.json> <devices-dir> <stable|testing> > manifest-<channel>.json
set -e

assets="$1"
devices_dir="$2"
channel="$3"

if [ -z "$assets" ] || [ ! -f "$assets" ] || [ ! -d "$devices_dir" ] || \
   { [ "$channel" != "stable" ] && [ "$channel" != "testing" ]; }; then
	echo "usage: $0 <assets.json> <devices-dir> <stable|testing>" >&2
	exit 1
fi

# Same explicit-glob check as make-index.sh: jq -s writes "[]" to stdout
# even when it cannot open the operand path, so a naive fallback would emit
# two concatenated JSON values.
set -- "$devices_dir"/*.json
if [ -e "$1" ]; then
	devices_json=$(jq -s '.' "$devices_dir"/*.json)
else
	devices_json='[]'
fi

generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Warnings go to stderr via a temp file written from inside jq? No -- jq
# cannot write stderr. Instead the jq program returns {manifest, skipped}
# and the shell prints the skip reasons afterward.
result=$(jq -n -S \
	--argjson devices "$devices_json" \
	--slurpfile assets_wrap "$assets" \
	--arg channel "$channel" \
	--arg generated "$generated" \
'
# Identical filename grammar to make-index.sh -- one convention, two joiners.
# combined (x86-style) parses but is NOT offered OTA: the manifest filter
# below stays sysupgrade-only, and x86 boards have no devices/*.json entry.
def parse_filename:
	capture("^openwrt-(?<target>[a-z0-9]+)-(?<subtarget>[a-z0-9]+)-(?<board>.+)-squashfs-(?<imgtype>sysupgrade|factory(-[a-z]+)?|combined(-[a-z]+)?)\\.(?<ext>bin|img|itb|img\\.gz)$")?;

# --slurpfile wraps the assets file (one JSON array) as [ <array> ]; unwrap it.
# Reading from a file rather than a --argjson arg avoids the jq ARG_MAX ceiling.
($assets_wrap[0]
	| map(. + {parsed: (.filename | parse_filename)})
	| map(select(.parsed != null and .parsed.imgtype == "sysupgrade"))
	| map(select($channel == "testing" or .channel == "stable"))
) as $imgs
|
# candidates per canonical board: an image matches a device if its parsed
# board equals the current board_name OR one of the legacy names -- a
# renamed board keeps its history reachable, though in practice only the
# newest release matters here.
[
	$devices[] | . as $dev
	| ([$dev.board_name] + ($dev.legacy_board_names // [])) as $names
	| ($imgs | map(select(.parsed.board as $b | $names | index($b)))
	         | sort_by(.date) | reverse) as $cand
	| if ($cand | length) == 0 then
		empty
	  elif ($dev.ota_board_name // null) == null then
		{skip: {board: $dev.board_name, reason: "no ota_board_name set -- refusing to publish an OTA entry with an unverified manifest key"}}
	  elif ($dev.eol // false) and ($dev.final_version == null) then
		{skip: {board: $dev.board_name, reason: "eol with no final_version -- nothing may be offered"}}
	  elif ($dev.min_ram_kb == null) or ($dev.min_flash_kb == null) then
		{skip: {board: $dev.board_name, reason: "hardware floors not measured (min_ram_kb/min_flash_kb null) -- refusing to offer OTA"}}
	  else
		( if ($dev.eol // false) then
			($cand | map(select((.tag | ltrimstr("v")) == $dev.final_version)) | .[0] // null)
		  else
			$cand[0]
		  end ) as $pick
		| if $pick == null then
			{skip: {board: $dev.board_name, reason: "eol final_version \($dev.final_version) has no matching sysupgrade image in this channel"}}
		  elif $pick.sha256 == null then
			{skip: {board: $dev.board_name, reason: "newest image \($pick.filename) has no sha256 sidecar -- refusing to offer unverifiable OTA"}}
		  elif ($pick.sig_url // null) == null then
			{skip: {board: $dev.board_name, reason: "newest image \($pick.filename) has no detached .sig -- refusing to offer unverifiable OTA"}}
		  else
			{entry: {
				key: $dev.ota_board_name,
				value: {
					version: ($pick.tag | ltrimstr("v")),
					date: $pick.date,
					url: $pick.url,
					sig_url: $pick.sig_url,
					sha256: $pick.sha256,
					size: $pick.size,
					min_ram_kb: $dev.min_ram_kb,
					min_flash_kb: $dev.min_flash_kb,
					eol: ($dev.eol // false),
					note: ($dev.note // null),
					changelog: "https://github.com/ispyisail/gargoyle-firmware/releases/tag/\($pick.tag)"
				}
			}}
		  end
	  end
] as $rows
|
{
	manifest: {
		schema: 1,
		channel: $channel,
		generated: $generated,
		devices: ([ $rows[] | select(.entry) | .entry ] | from_entries)
	},
	skipped: [ $rows[] | select(.skip) | .skip ]
}
')

printf '%s\n' "$result" | jq -r --arg channel "$channel" \
	'.skipped[] | "::warning::manifest(" + $channel + "): " + .board + " skipped: " + .reason' >&2 || true
printf '%s\n' "$result" | jq -S '.manifest'
