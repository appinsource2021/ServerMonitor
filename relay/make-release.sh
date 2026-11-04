#!/bin/sh
# Builds the relay downloads for the website into official/downloads/ (gitignored; copied at deploy).
set -eu
cd "$(dirname "$0")"
out=../official/downloads
mkdir -p "$out"
for arch in amd64 arm64; do
	tmp=$(mktemp -d)
	d="$tmp/srvmon-relay"
	mkdir -p "$d"
	CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -trimpath -ldflags "-s -w" -o "$d/srvmon-relay" .
	cp setup.sh README.md "$d/"
	tar -czf "$out/srvmon-relay-linux-$arch.tar.gz" -C "$tmp" srvmon-relay
	rm -rf "$tmp"
done
(cd "$out" && shasum -a 256 srvmon-relay-linux-*.tar.gz > SHA256SUMS)
cat "$out/SHA256SUMS"
