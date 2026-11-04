#!/bin/sh
# Builds the zip for Dashboard → Projects → New project → Upload existing project.
# The relay runs there as a plain process: the workspace has no Docker. See docs/URUN-YOL-HARITASI.md § 4.
set -eu
cd "$(dirname "$0")"
out="${1:-$HOME/Downloads/srvmon-relay-workspace.zip}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
d="$tmp/srvmon-relay"
mkdir -p "$d"
cp go.mod ./*.go README.md "$d/"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o "$d/srvmon-relay" .
printf 'data/\n.env\n' > "$d/.gitignore"
cat > "$d/CLAUDE.md" <<'MD'
# srvmon-relay

Relay of the Server Monitor app. Source of truth: github.com/appinsource2021/ServerMonitor, folder relay/.
Do not edit the code here; change it in that repository and upload a new zip.

Test server command: `RELAY_ADDR=0.0.0.0:{port} RELAY_DATA=./data ./srvmon-relay`

- Needs no database.
- The preview must be public: agents and phones cannot pass a sign-in page.
- `data/` holds relay.json and admin-token. Never commit it, never print admin-token into chat.
MD
rm -f "$out"
(cd "$tmp" && zip -qr "$out" srvmon-relay)
echo "OK $out"
