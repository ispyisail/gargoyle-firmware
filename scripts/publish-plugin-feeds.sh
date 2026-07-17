#!/bin/sh
# publish-plugin-feeds.sh -- publish the Gargoyle plugin feed as a set of
# per-arch GitHub Releases, one release per libc arch, tagged
# "plugins-<major>-<arch>". Each release holds every gargoyle-built .ipk for
# that arch plus a usign-signed opkg index (Packages / Packages.gz /
# Packages.sig). The firmware's `src/gz gargoyle` line
# (package/gpkg/files/opkg.gpkg.tmp) points a router straight at one of these
# releases' download base.
#
# Arch-keyed, not target/profile-keyed: gargoyle plugins are built per libc
# arch (bin/packages/<arch>/base/) and several targets share one arch, so an
# arch feed publishes each package once instead of once per profile.
#
# The index is built by make-feed.sh via gather-local-assets.sh with file://
# URLs -- so it is generated from the local .ipk bytes already on disk, no
# re-download. The co-location rule make-feed.sh documents still holds: the
# index and the .ipks it lists ship in the SAME release, because opkg
# resolves both off one src/gz base (no absolute-URL Filename support).
#
# Signing: Packages is usign-signed with the OTA key so `check_signature`
# stays on. Two ways to reach usign, since it only exists inside the builder
# container, never on a bare host:
#   - USIGN set to a usign path + KEY_SEC/KEY_PUB local files -> sign directly
#   - CONTAINER set (e.g. gargoyle-builder) + USIGN_IN_CONTAINER + KEY_SEC/PUB
#     -> docker cp the key in, sign via docker exec, clean up. (CI path.)
#
# Usage:
#   publish-plugin-feeds.sh <owner/repo> <major> <pkgroot1> [<pkgroot2> ...]
# where each <pkgrootN> is a "<target>-src/bin/packages" directory (one per
# built target). Arch dirs found beneath them are unioned, so x86's three
# sub-arches and the other targets' single arches all get their own feed.
#
# Env:
#   USIGN            path to a usign binary (host-side signing)
#   CONTAINER        docker container holding usign (container-side signing)
#   USIGN_IN_CONTAINER  usign path inside CONTAINER
#   KEY_SEC, KEY_PUB    OTA private/public key files (host paths)
#   CHANNEL         release prerelease flag: "testing" (default) -> --prerelease
#   DRY_RUN         if set, build+sign locally but do not create/upload releases
set -e

repo="$1"; major="$2"; shift 2 || true
if [ -z "$repo" ] || [ -z "$major" ] || [ "$#" -lt 1 ]; then
	echo "usage: $0 <owner/repo> <major> <pkgroot1> [pkgroot2 ...]" >&2
	exit 1
fi
: "${KEY_SEC:?KEY_SEC (OTA private key) not set}"
: "${KEY_PUB:?KEY_PUB (OTA public key) not set}"
[ -f "$KEY_SEC" ] || { echo "KEY_SEC $KEY_SEC not found" >&2; exit 1; }
[ -f "$KEY_PUB" ] || { echo "KEY_PUB $KEY_PUB not found" >&2; exit 1; }
CHANNEL="${CHANNEL:-testing}"

self_dir=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"; [ -n "$CONTAINER" ] && docker exec "$CONTAINER" rm -rf "$CONTAINER_WORK" 2>/dev/null || true' EXIT

# --- sign helper: usign -S over $1 (a Packages file) -> $2 (the .sig) ------
CONTAINER_WORK=/tmp/plugin-feed-sign.$$
if [ -n "$CONTAINER" ]; then
	: "${USIGN_IN_CONTAINER:?USIGN_IN_CONTAINER not set (usign path inside $CONTAINER)}"
	docker exec "$CONTAINER" mkdir -p "$CONTAINER_WORK"
	docker cp "$KEY_SEC" "$CONTAINER:$CONTAINER_WORK/ota.sec"
	sign() { # $1 = local Packages path, $2 = local .sig output path
		docker cp "$1" "$CONTAINER:$CONTAINER_WORK/P"
		docker exec "$CONTAINER" "$USIGN_IN_CONTAINER" -S -m "$CONTAINER_WORK/P" -s "$CONTAINER_WORK/ota.sec" -x "$CONTAINER_WORK/P.sig"
		docker cp "$CONTAINER:$CONTAINER_WORK/P.sig" "$2"
	}
else
	: "${USIGN:?either USIGN (host usign) or CONTAINER must be set}"
	sign() { "$USIGN" -S -m "$1" -s "$KEY_SEC" -x "$2"; }
fi

# --- collect the set of arch dirs across every package root ----------------
arches=$(for root in "$@"; do
	[ -d "$root" ] || continue
	for archdir in "$root"/*/; do
		[ -d "${archdir}base" ] || continue
		ls "${archdir}base"/*.ipk >/dev/null 2>&1 || continue
		basename "$archdir"
	done
done | sort -u)

[ -n "$arches" ] || { echo "::error::no arch package dirs with .ipks found under: $*" >&2; exit 1; }

extra_flag=""
[ "$CHANNEL" = "testing" ] && extra_flag="--prerelease"

# Stage every arch's ipks in the layout gather-local-assets.sh expects:
# <staging>/<channel>/<tag>/<file>. Then build ALL indexes in one make-feed
# pass -- the base_url is set to point INSIDE the channel dir so its file://
# URLs (base/<tag>/<file>) resolve to the real staged files.
stageroot="$work/stage"
for arch in $arches; do
	tag="plugins-$major-$arch"
	stage="$stageroot/$CHANNEL/$tag"
	mkdir -p "$stage"
	for root in "$@"; do
		[ -d "$root/$arch/base" ] || continue
		cp "$root/$arch/base"/*.ipk "$stage/" 2>/dev/null || true
	done
	n=$(ls "$stage"/*.ipk 2>/dev/null | wc -l | tr -d ' ')
	echo "$tag: $n packages staged" >&2
done

assets="$work/assets.json"
sh "$self_dir/gather-local-assets.sh" "$stageroot" "file://$stageroot/$CHANNEL" > "$assets"
feedout="$work/feedout"
sh "$self_dir/make-feed.sh" "$assets" "$work/dl" "$feedout"

for arch in $arches; do
	tag="plugins-$major-$arch"
	stage="$stageroot/$CHANNEL/$tag"
	pkgs="$feedout/$tag/Packages"
	[ -f "$pkgs" ] || { echo "::error::$tag: make-feed produced no Packages" >&2; exit 1; }

	# Sign Packages -> Packages.sig, and self-verify before publishing.
	sign "$pkgs" "$pkgs.sig"
	if [ -n "$CONTAINER" ]; then
		docker cp "$KEY_PUB" "$CONTAINER:$CONTAINER_WORK/ota.pub"
		docker cp "$pkgs" "$CONTAINER:$CONTAINER_WORK/V"
		docker cp "$pkgs.sig" "$CONTAINER:$CONTAINER_WORK/V.sig"
		docker exec "$CONTAINER" "$USIGN_IN_CONTAINER" -V -m "$CONTAINER_WORK/V" -x "$CONTAINER_WORK/V.sig" -p "$CONTAINER_WORK/ota.pub"
	else
		"$USIGN" -V -m "$pkgs" -x "$pkgs.sig" -p "$KEY_PUB"
	fi
	echo "$tag: index signed + verified ($(grep -c '^Package:' "$pkgs") pkgs)" >&2

	if [ -n "$DRY_RUN" ]; then
		echo "$tag: DRY_RUN, not publishing" >&2
		continue
	fi

	# Draft-first, publish-last (same reason as build-release.yml): the
	# release:published event must fire with every asset already in place.
	gh release view "$tag" --repo "$repo" >/dev/null 2>&1 || \
		gh release create "$tag" --repo "$repo" --title "$tag" \
			--notes "Gargoyle plugin feed for $arch (opkg \`src/gz gargoyle\`). Auto-published; index usign-signed with the OTA key." \
			--draft $extra_flag
	gh release upload "$tag" "$stage"/*.ipk --repo "$repo" --clobber
	gh release upload "$tag" "$pkgs" "$pkgs.gz" "$pkgs.sig" --repo "$repo" --clobber
	gh release edit "$tag" --repo "$repo" --draft=false
	echo "$tag: published" >&2
done

echo "all plugin feeds done" >&2
