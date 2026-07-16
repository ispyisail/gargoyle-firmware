#!/bin/sh
# make-feed.sh -- build an opkg Packages/Packages.gz feed index for each
# "plugins-<major>-<arch>" release found in a flat asset-record array (the
# same shape gather-local-assets.sh/gather-github-assets.sh produce).
#
# IMPORTANT, verified against opkg's own source (libopkg/opkg_download.c
# opkg_download_pkg(), libopkg/opkg_cmd.c the `update` path): opkg resolves
# BOTH the package list AND every package's Filename field by concatenating
# them onto the SAME `src/gz <name> <url>` base with a single "%s/%s" --
# there is no support for an absolute URL in a Filename field, and the index
# itself is fetched from that same base too. That means the Packages/
# Packages.gz this script produces MUST be uploaded as an asset into the
# exact same release as the .ipks it describes (an earlier draft of the
# hosting RFC assumed the index could live on Pages while packages rode the
# release CDN -- that does not work with real opkg and has been corrected).
# The firmware's default `src/gz gargoyle_core <url>` then points directly
# at that release's own download base.
#
# Because plugin .ipks are small (a few KB to low hundreds of KB, unlike
# multi-MB+ firmware images), this script downloads each one directly to
# extract its REAL control-file fields (Depends, Provides, Description...)
# and to hash/size the actual bytes -- no sidecar-hash convention needed
# here the way make-index.sh needs one for firmware images.
#
# Usage: make-feed.sh <assets.json> <tmp-download-dir> <out-dir>
# Writes <out-dir>/<tag>/Packages and <out-dir>/<tag>/Packages.gz for every
# distinct tag matching ^plugins-[0-9]+\.[0-9]+(\.[0-9]+)?-.+$ that has at
# least one non-.sha256 asset.
set -e

assets="$1"
tmpdir="$2"
outdir="$3"

if [ -z "$assets" ] || [ -z "$tmpdir" ] || [ -z "$outdir" ] || [ ! -f "$assets" ]; then
	echo "usage: $0 <assets.json> <tmp-download-dir> <out-dir>" >&2
	exit 1
fi
mkdir -p "$tmpdir" "$outdir"

self_dir=$(cd "$(dirname "$0")" && pwd)
control_awk="$self_dir/parse-control.awk"

# Real Debian/opkg control format: colon + exactly ONE mandatory separator
# space; any further leading whitespace is literal value content (Gargoyle's
# own control files carry a double space on some Description lines, and the
# real Packages index this script imitates preserves it verbatim). Same rule
# for continuation lines. Ships alongside this script -- see its own header
# for the parse rule this mirrors.

tags=$(jq -r '
	[.[] | select(.filename | endswith(".sha256") | not)
	      | select(.tag | test("^plugins-[0-9]+\\.[0-9]+(\\.[0-9]+)?-.+$"))
	      | .tag] | unique[]
' "$assets")

if [ -z "$tags" ]; then
	echo "make-feed.sh: no plugins-<major>-<arch> tagged assets found -- nothing to do" >&2
	exit 0
fi

printf '%s\n' "$tags" | while IFS= read -r tag; do
	echo "make-feed.sh: building feed for $tag" >&2
	tagdir="$tmpdir/$tag"
	mkdir -p "$tagdir" "$outdir/$tag"

	pkg_records="[]"
	records=$(jq -c --arg tag "$tag" '.[] | select(.tag == $tag) | select(.filename | endswith(".sha256") | not)' "$assets")

	printf '%s\n' "$records" | while IFS= read -r rec; do
		filename=$(printf '%s\n' "$rec" | jq -r '.filename')
		url=$(printf '%s\n' "$rec" | jq -r '.url')
		dest="$tagdir/$filename"

		if ! curl -fsSL "$url" -o "$dest"; then
			echo "::warning::make-feed.sh: could not download $url -- skipping $filename" >&2
			continue
		fi

		# Real bytes are the source of truth for Size/SHA256sum, not
		# whatever the release's own metadata claims -- we already have
		# the file downloaded for control extraction, so hashing it
		# directly here costs nothing and needs no sidecar convention.
		size=$(wc -c < "$dest" | tr -d ' ')
		sha256=$(sha256sum "$dest" | awk '{print $1}')

		# An .ipk is a plain gzipped tar (NOT an ar archive like .deb)
		# containing ./debian-binary, ./data.tar.gz, ./control.tar.gz --
		# verified against real Gargoyle-built ipks, not assumed from the
		# Debian format. Two-stage extract: pull control.tar.gz out of the
		# ipk, then the control file out of that.
		control_kv=$(tar xzf "$dest" -O ./control.tar.gz 2>/dev/null | tar xzf - -O ./control 2>/dev/null || true)
		if [ -z "$control_kv" ]; then
			echo "::warning::make-feed.sh: could not read control file from $filename -- skipping" >&2
			continue
		fi

		# parse-control.awk separates records/fields with non-newline marker
		# bytes (generated via awk's own sprintf("%c",N), never embedded as
		# literal bytes in source) specifically because a real control-file
		# value like Description legitimately contains embedded newlines --
		# splitting naively on "\n"/"\t" shreds a multi-line value into bogus
		# extra top-level keys (caught by testing against a real multi-line
		# Description before this script shipped). Generate the same two
		# marker bytes here via printf's octal escapes (POSIX, portable) and
		# hand them to jq as arguments rather than writing them into the jq
		# program text itself.
		rec_sep=$(printf '\036')
		kv_sep=$(printf '\037')
		# printf, NOT echo: /bin/sh here is dash, whose builtin echo
		# interprets backslash escapes (e.g. a literal "\n" two-char
		# sequence inside JSON-serialized text) by default -- confirmed
		# live: it silently turned an escaped "\n" in a real multi-line
		# Description into a raw, unescaped newline byte, which the next
		# jq stage then rejected as invalid JSON ("control characters ...
		# must be escaped"). printf '%s\n' never interprets its argument.
		fields_json=$(printf '%s\n' "$control_kv" | awk -f "$control_awk" | jq -R -s --arg rs "$rec_sep" --arg us "$kv_sep" '
			split($rs) | map(select(length > 0)) | map(split($us)) | map({(.[0]): .[1]}) | add // {}
		')

		pkg_obj=$(printf '%s\n' "$fields_json" | jq --arg filename "$filename" --argjson size "$size" --arg sha256 "$sha256" \
			'{
				Package: .Package,
				Version: .Version,
				Depends: .Depends,
				Provides: .Provides,
				Section: .Section,
				Architecture: .Architecture,
				"Installed-Size": ."Installed-Size",
				Filename: $filename,
				Size: ($size | tostring),
				SHA256sum: $sha256,
				Description: .Description
			}')

		printf '%s\n' "$pkg_obj" >> "$tagdir/.packages.ndjson"
	done

	[ -f "$tagdir/.packages.ndjson" ] || { echo "::warning::make-feed.sh: $tag had no downloadable packages" >&2; continue; }

	# Render each package object into a real Packages stanza: fixed field
	# order matching what opkg's own generator actually produces (Source/
	# SourceName/SourceDateEpoch/Maintainer from the raw control file are
	# dropped -- confirmed against a real OpenWrt-built Packages index),
	# multi-line values (Description) re-joined as "Key: line1\n line2..."
	# -- one leading space per continuation line, same convention parsed.
	#
	# Stanzas are joined with "\n\n" (blank line) as ONE single top-level jq
	# value, not streamed one-per-package via `.[] | ...`: a plain per-line
	# awk pass afterward can't tell a stanza boundary from an ordinary
	# multi-line field boundary (Description spans several physical lines
	# too), and a first attempt at that confirmed it live -- it inserted a
	# blank line before every line in the file, not just between packages.
	# jq already knows exactly where each package ends; joining there is the
	# only place this can be done correctly.
	jq -s '.' "$tagdir/.packages.ndjson" | jq -r '
		def render_field(name; val):
			if (val == null or val == "") then empty
			else
				(val | split("\n")) as $lines
				| ([name + ": " + $lines[0]] + ($lines[1:] | map(" " + .))) | join("\n")
			end;
		[ .[] | [
			render_field("Package"; .Package),
			render_field("Version"; .Version),
			render_field("Depends"; .Depends),
			render_field("Provides"; .Provides),
			render_field("Section"; .Section),
			render_field("Architecture"; .Architecture),
			render_field("Installed-Size"; ."Installed-Size"),
			render_field("Filename"; .Filename),
			render_field("Size"; .Size),
			render_field("SHA256sum"; .SHA256sum),
			render_field("Description"; .Description)
		] | map(select(. != "")) | join("\n") ] | join("\n\n")
	' > "$outdir/$tag/Packages"

	gzip -9 -n -c "$outdir/$tag/Packages" > "$outdir/$tag/Packages.gz"

	echo "make-feed.sh: $tag -> $(grep -c '^Package:' "$outdir/$tag/Packages") package(s)" >&2
done
