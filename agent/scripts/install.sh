#!/bin/sh
# Installs or updates srvmon-agent. The iOS app uploads the binary (and, on
# first install, a config) over SFTP and runs this script as root over SSH.
#
#   sh install.sh <uploaded-binary> [uploaded-config.json]
#
# An existing /etc/srvmon/config.json is kept on updates.
set -eu

BIN_SRC="${1:?usage: install.sh <binary> [config.json]}"
CFG_SRC="${2:-}"
BIN=/usr/local/bin/srvmon-agent
CFG_DIR=/etc/srvmon
UNIT=/etc/systemd/system/srvmon-agent.service

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root" >&2
  exit 10
fi
if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemd is required" >&2
  exit 11
fi

"$BIN_SRC" version >/dev/null 2>&1 || { echo "ERROR: uploaded binary does not run on this machine ($(uname -m))" >&2; exit 12; }

install -m 0755 "$BIN_SRC" "$BIN.new"
mv -f "$BIN.new" "$BIN"
rm -f "$BIN_SRC"

mkdir -p "$CFG_DIR"
chmod 0700 "$CFG_DIR"
if [ -n "$CFG_SRC" ]; then
  if [ ! -f "$CFG_DIR/config.json" ]; then
    install -m 0600 "$CFG_SRC" "$CFG_DIR/config.json"
  fi
  rm -f "$CFG_SRC"
fi

cat > "$UNIT" <<'UNIT'
[Unit]
Description=srvmon agent (server monitor for iOS)
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/srvmon-agent run -config /etc/srvmon/config.json
Restart=always
RestartSec=5
RuntimeDirectory=srvmon
RuntimeDirectoryMode=0750
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true
ReadWritePaths=/etc/srvmon

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable srvmon-agent >/dev/null 2>&1
systemctl restart srvmon-agent

i=0
while [ $i -lt 20 ]; do
  if "$BIN" api GET /v1/health 2>/dev/null | head -n1 | grep -q '^HTTP 200'; then
    echo "OK srvmon-agent $("$BIN" version) running"
    exit 0
  fi
  i=$((i + 1))
  sleep 0.5
done
echo "ERROR: agent did not become healthy" >&2
journalctl -u srvmon-agent -n 20 --no-pager >&2 || true
exit 13
