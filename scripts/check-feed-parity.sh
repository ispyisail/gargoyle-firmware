#!/bin/sh
# check-feed-parity.sh -- fail if the per-arch plugin feeds being published
# in one run disagree about which gargoyle plugins they carry.
#
# Why this exists: the captive portal plugin shipped in the x86 feed but was
# missing from mediatek/ath79/ipq40xx, because it was only ever enabled for
# x86 at build time (unlike the ~40 auto-selected plugins it compiles a C
# helper and has extra deps, so it is not pulled into every target's package
# set automatically). Nobody noticed until an MT6000 user found it absent.
# Every gargoyle plugin is expected to exist for every arch; a divergence
# almost always means a per-target build-config gap like that one.
#
# It reads the freshly built per-arch Packages indexes (one dir per arch,
# each containing a Packages file), takes the set of `plugin-gargoyle-*`
# package names in each, and fails if any arch is missing a plugin that
# another arch has -- unless that plugin is in the allow-list.
#
# Genuinely arch-specific plugins (should be rare) go in FEED_PARITY_ALLOW,
# a space-separated list of package names exempt from the parity requirement.
#
# Usage: check-feed-parity.sh <archdir1> <archdir2> [...]
#   each <archdirN> is a directory whose immediate child "Packages" is that
#   arch's opkg index (i.e. make-feed's $feedout/<tag> dirs).
# Env: FEED_PARITY_ALLOW  space-separated package names to exempt.
# Exit 0 = feeds agree (or <2 arches, nothing to compare), 1 = divergence.
set -e

# Byte-order collation for every sort/comm below. Package names are mixed
# case (e.g. plugin-gargoyle-theme-Gargoyle-Modern); under a UTF-8 locale
# `sort` and `comm` can disagree on order, which makes comm abort with
# "not in sorted order". C locale keeps the two consistent.
export LC_ALL=C

if [ "$#" -lt 1 ]; then
	echo "usage: $0 <archdir-with-Packages> [<archdir2> ...]" >&2
	exit 2
fi

allow=" ${FEED_PARITY_ALLOW:-} "   # padded so word-boundary grep is simple

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Collect, per arch, the sorted set of plugin-gargoyle-* package names.
arch_count=0
for dir in "$@"; do
	pkgs="$dir/Packages"
	[ -f "$pkgs" ] || { echo "::warning::check-feed-parity: no Packages in $dir -- skipping" >&2; continue; }
	arch=$(basename "$dir")
	awk '/^Package:[ \t]+plugin-gargoyle-/ { print $2 }' "$pkgs" | sort -u > "$work/$arch.set"
	arch_count=$((arch_count + 1))
	echo "$arch" >> "$work/arches"
done

if [ "$arch_count" -lt 2 ]; then
	echo "check-feed-parity: only $arch_count arch feed(s) present -- nothing to compare"
	exit 0
fi

# Union of every plugin seen in any arch.
cat "$work"/*.set | sort -u > "$work/union"

# For each arch, list plugins in the union it does NOT have and that are not
# allow-listed. Any such line is a divergence.
divergence=0
while IFS= read -r arch; do
	# plugins in union but not in this arch
	missing=$(comm -23 "$work/union" "$work/$arch.set")
	[ -n "$missing" ] || continue
	for m in $missing; do
		case "$allow" in
			*" $m "*) continue ;;   # allow-listed, not a failure
		esac
		echo "MISSING: $m  is in another arch's feed but not in $arch" >&2
		divergence=1
	done
done < "$work/arches"

if [ "$divergence" -ne 0 ]; then
	echo "" >&2
	echo "Plugin feed parity check FAILED: the arch feeds above disagree on" >&2
	echo "which gargoyle plugins they carry. Every plugin should build for" >&2
	echo "every target -- a missing one usually means it is not enabled in" >&2
	echo "that target's profile config (targets/<t>/profiles/<p>/config) or" >&2
	echo "is not pulled into its package set. Fix the build, or -- only if the" >&2
	echo "plugin really is arch-specific -- add it to FEED_PARITY_ALLOW." >&2
	exit 1
fi

echo "check-feed-parity: OK ($arch_count arches agree on $(wc -l < "$work/union" | tr -d ' ') gargoyle plugins)"
