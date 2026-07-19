#!/bin/sh
# check-board-names.sh -- fail if a devices/*.json's ota_board_name doesn't
# match the real runtime board_name baked into its own newest release
# image.
#
# Why this exists: every devices/*.json shipped with ota_board_name (née
# board_name, before it was split out -- see devices/README.md) set to the
# underscore build/filename slug instead of the real comma-separated
# runtime value. The OTA manifest published that wrong key for every
# device, on every channel, from the very first release -- a router's
# ota_upgrade.sh check never had anything to match against, and nothing
# anywhere ever errored: `not-listed` is also the correct response for a
# genuinely unsupported board, so a real bug and "nothing to offer this
# board yet" were indistinguishable from the outside. Found only by
# accident, testing OTA against real hardware weeks after the first
# release shipped.
#
# What this checks: for every devices/*.json with ota_board_name set, find
# its newest sysupgrade image in assets.json (same board_name/
# legacy_board_names filename join make-manifest.sh uses), download it,
# and run fwtool against the REAL bytes -- the same ground truth
# devices/README.md tells a human to check by hand. Fails loudly on any
# mismatch instead of silently publishing an unreachable manifest entry.
#
# A device with no ota_board_name, or with no matching image in this run,
# is skipped (not a failure) -- both are legitimate states (OTA not wired
# up yet for that board; board just wasn't built this round).
#
# Usage: check-board-names.sh <assets.json> <devices-dir>
# Requires: jq, curl, and a running gargoyle-builder container with a
#           built target's staging_dir/host/bin/fwtool somewhere inside it
#           (any target's fwtool works -- it's target-independent).
set -e

assets="$1"
devices_dir="$2"

if [ -z "$assets" ] || [ ! -f "$assets" ] || [ -z "$devices_dir" ] || [ ! -d "$devices_dir" ]; then
	echo "usage: $0 <assets.json> <devices-dir>" >&2
	exit 2
fi

set -- "$devices_dir"/*.json
if [ -e "$1" ]; then
	devices_json=$(jq -s '.' "$devices_dir"/*.json)
else
	echo "# no devices/*.json found in $devices_dir -- nothing to check"
	exit 0
fi

# Only devices that actually opt into OTA are worth checking -- see header.
to_check="$(printf '%s' "$devices_json" | jq -c '[.[] | select(.ota_board_name != null)]')"
_n="$(printf '%s' "$to_check" | jq 'length')"
if [ "$_n" = 0 ]; then
	echo "# no devices/*.json entries have ota_board_name set -- nothing to check"
	exit 0
fi

fwtool_path=$(docker exec gargoyle-builder sh -c \
	'find /build/gargoyle -maxdepth 6 -path "*/staging_dir/host/bin/fwtool" 2>/dev/null | head -1')
if [ -z "$fwtool_path" ]; then
	echo "::error::check-board-names: no fwtool binary found in any target staging_dir inside the builder container -- build at least one target first" >&2
	exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"; docker exec gargoyle-builder rm -rf /tmp/check-board-names 2>/dev/null || true' EXIT
docker exec gargoyle-builder mkdir -p /tmp/check-board-names

fail=0
i=0
while [ "$i" -lt "$_n" ]; do
	dev="$(printf '%s' "$to_check" | jq -c ".[$i]")"
	board_name="$(printf '%s' "$dev" | jq -r '.board_name')"
	ota_board_name="$(printf '%s' "$dev" | jq -r '.ota_board_name')"
	legacy="$(printf '%s' "$dev" | jq -c '.legacy_board_names // []')"
	i=$((i + 1))

	# Same filename-join candidate selection as make-manifest.sh: parse
	# each asset's board out of its filename, match against board_name or
	# any legacy_board_names, sysupgrade only, newest by date wins.
	pick="$(jq -c --argjson names "$(printf '%s' "$legacy" | jq -c ". + [\"$board_name\"]")" '
		def parse_filename:
			capture("^openwrt-(?<target>[a-z0-9]+)-(?<subtarget>[a-z0-9]+)-(?<board>.+)-squashfs-(?<imgtype>sysupgrade|factory(-[a-z]+)?|combined(-[a-z]+)?)\\.(?<ext>bin|img|itb|img\\.gz)$")?;
		map(. + {parsed: (.filename | parse_filename)})
		| map(select(.parsed != null and .parsed.imgtype == "sysupgrade"))
		| map(select(.parsed.board as $b | $names | index($b)))
		| sort_by(.date) | reverse | .[0] // null
	' "$assets")"

	if [ "$pick" = "null" ] || [ -z "$pick" ]; then
		echo "# $board_name: no matching sysupgrade image in this run -- skipping"
		continue
	fi

	img_url="$(printf '%s' "$pick" | jq -r '.url')"
	img_file="$(printf '%s' "$pick" | jq -r '.filename')"
	img_tag="$(printf '%s' "$pick" | jq -r '.tag')"

	if ! curl -fsSL -o "$work/$img_file" "$img_url"; then
		echo "::error::check-board-names: $board_name: failed to download $img_url" >&2
		fail=1
		continue
	fi

	docker cp "$work/$img_file" "gargoyle-builder:/tmp/check-board-names/$img_file"
	real_devices="$(docker exec gargoyle-builder "$fwtool_path" -i - "/tmp/check-board-names/$img_file" 2>/dev/null | jq -c '.supported_devices // []')"
	rm -f "$work/$img_file"
	docker exec gargoyle-builder rm -f "/tmp/check-board-names/$img_file"

	if printf '%s' "$real_devices" | jq -e --arg want "$ota_board_name" 'index($want) != null' >/dev/null 2>&1; then
		echo "# $board_name: ota_board_name '$ota_board_name' confirmed against $img_file ($img_tag)"
	else
		echo "::error::check-board-names: $board_name declares ota_board_name '$ota_board_name', but $img_file's real supported_devices is $real_devices -- fix devices/$board_name.json before this can publish an OTA entry" >&2
		fail=1
	fi
done

exit "$fail"
