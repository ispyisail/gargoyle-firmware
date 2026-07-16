#!/bin/sh
# gather-github-assets.sh -- the production counterpart to
# gather-local-assets.sh: walks every GitHub Release on this repo via `gh
# api` and emits the same canonical asset-record array make-index.sh
# consumes, so the exact same indexing logic runs in CI and in local tests.
#
# Channel is inferred from the tag: anything with an -rc/-beta/-alpha/
# -testing suffix is "testing", everything else is "stable" -- keeps channel
# assignment mechanical (build the release, tag it right) rather than a
# separate manual step per release.
#
# sha256 is read from a sidecar asset "<filename>.sha256" uploaded alongside
# every image by build-release.yml -- NOT computed here. Downloading each
# multi-hundred-MB image just to hash it would blow the runner's time/
# bandwidth budget for zero benefit; a missing sidecar is reported as a
# workflow warning with sha256 left null rather than silently fetching the
# full image.
#
# Requires: gh (authenticated; GITHUB_TOKEN is sufficient for a public repo),
# jq, curl.
#
# Usage: gather-github-assets.sh <owner/repo> > assets.json
set -e

repo="$1"
if [ -z "$repo" ]; then
	echo "usage: $0 <owner/repo>" >&2
	exit 1
fi

tmp_records=$(mktemp)
trap 'rm -f "$tmp_records"' EXIT

gh api "repos/$repo/releases" --paginate --jq '.' \
	| jq -s 'add' \
	| jq -c '
		.[] | select(.draft == false) as $r
		| ($r.assets) as $all
		| ($all | map(select(.name | endswith(".sha256") | not))) as $imgs
		| $imgs[] | . as $img
		| {
			tag: $r.tag_name,
			channel: (if ($r.tag_name | test("-(rc|beta|alpha|testing)[0-9]*$"; "i"))
				then "testing" else "stable" end),
			filename: $img.name,
			url: $img.browser_download_url,
			size: $img.size,
			date: $r.published_at,
			sidecar_url: ( ($all | map(select(.name == ($img.name + ".sha256"))) | .[0].browser_download_url) // null )
		}
	' > "$tmp_records"

# Resolve each record's sha256 by curling its sidecar (tiny file, ~64 bytes)
# rather than downloading the image itself.
first=1
printf '['
while IFS= read -r rec; do
	sidecar_url=$(echo "$rec" | jq -r '.sidecar_url')
	filename=$(echo "$rec" | jq -r '.filename')
	tag=$(echo "$rec" | jq -r '.tag')
	if [ "$sidecar_url" != "null" ]; then
		sha256=$(curl -fsSL "$sidecar_url" 2>/dev/null | awk '{print $1}')
	else
		echo "::warning::no .sha256 sidecar for $filename (tag $tag) -- sha256 will be null" >&2
		sha256=""
	fi
	[ "$first" = 1 ] || printf ','
	first=0
	echo "$rec" | jq --arg sha256 "$sha256" \
		'del(.sidecar_url) + {sha256: (if $sha256 == "" then null else $sha256 end)}'
done < "$tmp_records"
printf ']\n'
