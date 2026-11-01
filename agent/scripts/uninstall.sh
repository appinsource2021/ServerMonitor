#!/bin/sh
# Removes srvmon-agent. Pass --purge to also delete /etc/srvmon (config, APNs key).
set -eu
systemctl disable --now srvmon-agent >/dev/null 2>&1 || true
rm -f /etc/systemd/system/srvmon-agent.service /usr/local/bin/srvmon-agent
systemctl daemon-reload || true
if [ "${1:-}" = "--purge" ]; then rm -rf /etc/srvmon; fi
echo "OK srvmon-agent removed"
