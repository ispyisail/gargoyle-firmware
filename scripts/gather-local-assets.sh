#!/bin/sh
# gather-local-assets.sh -- walk a local staging directory and emit the
# canonical asset-record array that make-index.sh consumes. This is the
# offline stand-in for the real gatherer (a `gh api releases` walk done
# directly in publish-site.yml) so make-index.sh and the Finder can be built
# and tested without a live repo or any release having been published yet.
#
# Expected layout:
#   <staging-dir>/<channel>/<tag>/<filename>
# e.g.
#   staging/stable/v1.16.0/openwrt-mediatek-filogic-glinet_gl-mt6000-squashfs-sysupgrade.bin
#
# Usage: gather-local-assets.sh <staging-dir> [base-url] > assets.json
#   base-url defaults to "file://<staging-dir>" (fine for local Finder
#   testing); pass the real releases base to rehearse production URLs, e.g.
#   https://github.com/<owner>/<repo>/releases/download
set -e

staging="$1"
base_url="${2:-file://$(cd "$staging" && pwd)}"

if [ -z "$staging" ] || [ ! -d "$staging" ]; then
	echo "usage: $0 <staging-dir> [base-url]" >&2
	exit 1
fi

first=1
printf '['
find "$staging" -mindepth 3 -maxdepth 3 -type f | sort | while read -r path; do
	# printf, not echo: /bin/sh is dash here, whose builtin echo interprets
	# backslash escapes by default -- a path containing a literal "\n"-like
	# sequence would be silently mangled. printf '%s\n' never does that.
	channel=$(printf '%s\n' "$path" | awk -F/ '{print $(NF-2)}')
	tag=$(printf '%s\n' "$path" | awk -F/ '{print $(NF-1)}')
	filename=$(basename "$path")

	# Skip sha256 sidecars -- they're read, not listed, as their own record.
	case "$filename" in
		*.sha256) continue ;;
	esac

	size=$(wc -c < "$path" | tr -d ' ')
	if [ -e "$path.sha256" ]; then
		sha256=$(awk '{print $1}' "$path.sha256")
	else
		sha256=$(sha256sum "$path" | awk '{print $1}')
	fi
	date=$(date -u -r "$path" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
	url="$base_url/$tag/$filename"

	[ "$first" = 1 ] || printf ','
	first=0
	jq -n --arg tag "$tag" --arg channel "$channel" --arg filename "$filename" \
		--arg url "$url" --arg sha256 "$sha256" --arg date "$date" --argjson size "$size" \
		'{tag: $tag, channel: $channel, filename: $filename, url: $url, sha256: $sha256, size: $size, date: $date}'
done
printf ']\n'
