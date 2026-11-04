#!/bin/sh
# Builds the one-file relay installer: srvmon-relay-setup.sh holds the amd64 and arm64 programs and
# setup.sh, and needs nothing from the internet. Usage: make-release.sh [output folder].
# Default output: official/downloads (website). `make ios-resources` also puts it into the app.
set -eu
cd "$(dirname "$0")"
out=${1:-../official/downloads}
mkdir -p "$out"
sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for arch in amd64 arm64; do
	CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -trimpath -ldflags "-s -w" -o "$tmp/srvmon-relay-$arch" .
done
cp setup.sh README.md "$tmp/"
tar -czf "$tmp.payload" -C "$tmp" srvmon-relay-amd64 srvmon-relay-arm64 setup.sh README.md
sha=$(sum "$tmp.payload" | awk '{print $1}')

cat > "$tmp.head" <<'HEAD'
#!/bin/sh
# Server Monitor relay installer. Makes this machine a relay.
# Run it on the machine that should be the relay:  sudo sh srvmon-relay-setup.sh
# The programs are packed below this script. Nothing is downloaded.
set -eu
case "$(uname -m)" in
x86_64|amd64) arch=amd64 ;;
aarch64|arm64) arch=arm64 ;;
*) echo "ERROR: unsupported CPU: $(uname -m)" >&2; exit 1 ;;
esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
tail -n +__LINE__ "$0" > "$tmp/payload"
if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$tmp/payload"); else got=$(shasum -a 256 "$tmp/payload"); fi
[ "${got%% *}" = "__SHA__" ] || { echo "ERROR: this file is damaged; get it again" >&2; exit 1; }
tar -xzf "$tmp/payload" -C "$tmp"
mv "$tmp/srvmon-relay-$arch" "$tmp/srvmon-relay"
chmod 755 "$tmp/srvmon-relay"
sh "$tmp/setup.sh"
exit $?
HEAD
line=$(($(wc -l < "$tmp.head") + 1))
sed -e "s/__LINE__/$line/" -e "s/__SHA__/$sha/" "$tmp.head" > "$out/srvmon-relay-setup.sh"
cat "$tmp.payload" >> "$out/srvmon-relay-setup.sh"
rm -f "$tmp.head" "$tmp.payload"
chmod 755 "$out/srvmon-relay-setup.sh"
(cd "$out" && sum srvmon-relay-setup.sh > srvmon-relay-setup.sh.sha256)
ls -la "$out/srvmon-relay-setup.sh"
