#!/bin/sh
# verify-image.sh -- verify a published Gargoyle sysupgrade image against
# the OTA public key: the same fail-closed sequence RFC #62's on-router
# client runs, packaged so a human (or CI) can check a downloaded image the
# same way a router would before flashing.
#
# Signatures are DETACHED (<image>.sig alongside the image), not appended
# into the image. Deliberate, discovered the hard way: the build itself
# already appends a ucert signature block to every image (BUILD_KEY,
# include/image-commands.mk), so an appended OTA signature would bury the
# native one in the very trailer slot stock sysupgrade's
# fwtool_check_signature pops -- breaking stock verification the day it is
# enforced. Detached signing also keeps every published byte identical to
# what the build produced, so the build tree's own sha256sums stay valid.
#
#   1. sha256 (optional)  -- the download-integrity check; also the only
#                            check available for the unsigned image
#                            families (factory, x86-style combined).
#   2. usign -V           -- the authenticity check, over the exact
#                            published bytes.
#
# Needs usign on PATH (or set USIGN). On the build host it exists only
# inside the builder container:
#   docker exec gargoyle-builder env \
#     USIGN=/build/gargoyle/<target>-src/staging_dir/host/bin/usign \
#     sh /tmp/verify-image.sh /tmp/image.bin /tmp/image.bin.sig /tmp/ota.pub
#
# Usage: verify-image.sh <image> <image.sig> <ota.pub> [expected-sha256]
set -e

img="$1"
sig="$2"
pub="$3"
expected_sha="$4"

USIGN="${USIGN:-usign}"

if [ -z "$img" ] || [ ! -f "$img" ] || [ -z "$sig" ] || [ ! -f "$sig" ] || [ -z "$pub" ] || [ ! -f "$pub" ]; then
	echo "usage: $0 <image> <image.sig> <ota.pub> [expected-sha256]" >&2
	exit 1
fi

if [ -n "$expected_sha" ]; then
	actual_sha=$(sha256sum "$img" | awk '{print $1}')
	if [ "$actual_sha" != "$expected_sha" ]; then
		echo "FAIL: sha256 mismatch" >&2
		echo "  expected: $expected_sha" >&2
		echo "  actual:   $actual_sha" >&2
		exit 1
	fi
	echo "ok: sha256 matches"
fi

if "$USIGN" -V -m "$img" -x "$sig" -p "$pub"; then
	echo "ok: signature verifies against $pub"
	echo "PASS: $img"
else
	echo "FAIL: signature does NOT verify against $pub" >&2
	echo "  -- image corrupted, signed with a different key, or tampered" >&2
	exit 1
fi
