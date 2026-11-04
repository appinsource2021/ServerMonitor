#!/bin/sh
# Writes .env and the relay's data to one archive, for a move or a backup. Run in relay/.
set -eu
[ -f .env ] || { echo "ERROR: run this in the relay folder (.env not found)" >&2; exit 1; }
out="srvmon-relay-backup-$(date +%Y%m%d-%H%M%S).tgz"
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp .env "$tmp/env"
docker run --rm -v srvmon-relay-data:/d:ro -v "$tmp":/b alpine cp -a /d/. /b/
tar -czf "$out" -C "$tmp" .
echo "OK $out (holds the admin token, keep it private)"
