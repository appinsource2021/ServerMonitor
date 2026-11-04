#!/bin/sh
# Puts a backup.sh archive back on this server. Run in relay/, before docker compose up.
set -eu
[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: ./restore.sh srvmon-relay-backup-<date>.tgz" >&2; exit 1; }
[ -f docker-compose.yml ] || { echo "ERROR: run this in the relay folder" >&2; exit 1; }
[ ! -f .env ] || { echo "ERROR: .env already exists; this server has a relay. Remove it first if you mean to replace it." >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tar -xzf "$1" -C "$tmp"
[ -f "$tmp/env" ] || { echo "ERROR: not a relay backup" >&2; exit 1; }
(umask 077; cp "$tmp/env" .env)
rm "$tmp/env"
docker volume create srvmon-relay-data >/dev/null
docker run --rm -v srvmon-relay-data:/d -v "$tmp":/b:ro alpine sh -c 'cp -a /b/. /d/ && chown -R 65532:65532 /d'
echo "OK restored. Next: docker compose up -d --build"
