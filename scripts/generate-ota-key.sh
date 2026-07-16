#!/bin/sh
# generate-ota-key.sh -- ONE-TIME setup: generates the usign keypair that
# signs every published firmware image (RFC #62). Not run automatically by
# any workflow -- this is a deliberate human action, run once, on the
# machine that will hold the private key forever.
#
# The private key NEVER leaves this machine and is NEVER stored as a GitHub
# secret: it lives only in the file this script writes, referenced by
# build-release.yml's self-hosted-runner job via $GARGOYLE_OTA_KEY_DIR. A
# compromised CI secret store cannot leak a key that was never put in one.
#
# The public key gets baked into every built image at /etc/gargoyle/ota.pub
# (that wiring is part of RFC #62's on-router OTA client work, not this
# script) so routers can verify what this key signs.
#
# Usage: generate-ota-key.sh <key-dir>
#   Writes <key-dir>/ota.sec (PRIVATE -- chmod 600, back this up somewhere
#   safe and offline; losing it means re-keying every future image) and
#   <key-dir>/ota.pub (safe to publish/commit/bake into images).
set -e

key_dir="$1"
if [ -z "$key_dir" ]; then
	echo "usage: $0 <key-dir>" >&2
	exit 1
fi

if [ -e "$key_dir/ota.sec" ]; then
	echo "refusing to overwrite existing $key_dir/ota.sec -- move it aside first if you really mean to re-key" >&2
	exit 1
fi

mkdir -p "$key_dir"
chmod 700 "$key_dir"

usign -G -s "$key_dir/ota.sec" -p "$key_dir/ota.pub" \
	-c "Gargoyle OTA signing key, generated $(date -u +%Y-%m-%d)"

chmod 600 "$key_dir/ota.sec"
chmod 644 "$key_dir/ota.pub"

echo "Generated:"
echo "  private (keep secret, back up offline): $key_dir/ota.sec"
echo "  public  (bake into images, safe to share): $key_dir/ota.pub"
echo
cat "$key_dir/ota.pub"
