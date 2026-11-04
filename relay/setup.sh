#!/bin/sh
# Server Monitor relay: setup assistant. Asks a few questions, shows what it will do, then does it.
# Run as root in the folder that holds the srvmon-relay binary:  sudo ./setup.sh
# Safe to run again: it keeps the existing admin token and data.
# DRY_RUN=1 prints every change instead of making it (answers are read from stdin).
set -eu

DRY=${DRY_RUN:-}
HERE=$(cd "$(dirname "$0")" && pwd)
ENV_FILE=/etc/srvmon-relay.env
DATA=/var/lib/srvmon-relay
UNIT=/etc/systemd/system/srvmon-relay.service

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
run()  { if [ -n "$DRY" ]; then say "  [dry run] $*"; else eval "$*"; fi; }
ask() { # ask "question" default → $REPLY
	if [ -n "${2:-}" ]; then printf '%s [%s]: ' "$1" "$2"; else printf '%s: ' "$1"; fi
	if [ -z "$DRY" ] && [ -r /dev/tty ]; then read -r REPLY </dev/tty; else read -r REPLY || REPLY=""; fi
	[ -n "$REPLY" ] || REPLY=${2:-}
}
yes_no() { # yes_no "question" y|n
	ask "$1 (y/n)" "$2"
	case "$REPLY" in y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}
active() { command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$1"; }
resolve() {
	if command -v getent >/dev/null 2>&1; then getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}'
	elif command -v dig >/dev/null 2>&1; then dig +short "$1" A | tail -n1
	fi
}
port_busy() { command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -q "[:.]$1\$"; }

say "Server Monitor relay setup"
say "The relay is the mailbox between your servers and your team's phones."
say "It runs on this machine. Your servers connect out to it, so they open no port."
say "Press Enter to take the value in [brackets]."

[ -n "$DRY" ] || [ "$(id -u)" = 0 ] || die "run this as root: sudo ./setup.sh"
[ -n "$DRY" ] || command -v systemctl >/dev/null 2>&1 || die "this assistant needs systemd"
[ -n "$DRY" ] || [ -x "$HERE/srvmon-relay" ] || die "srvmon-relay was not found next to this script"

step "1 of 4: Address"
say "Phones and servers will reach the relay at an https address, for example relay.example.com."
while :; do
	ask "Domain name" ""
	DOMAIN=$(printf '%s' "$REPLY" | tr 'A-Z' 'a-z' | sed 's#^https\{0,1\}://##; s#/.*$##')
	printf '%s' "$DOMAIN" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' && break
	say "That does not look like a domain name."
done
IP=$(resolve "$DOMAIN" || true)
if [ -z "$IP" ]; then
	say "$DOMAIN has no DNS record yet. Add an A record that points to this server."
	say "Certificates cannot be issued until it exists."
	yes_no "Continue anyway?" n || exit 0
else
	say "$DOMAIN points to $IP. It must be this server's public address."
fi

step "2 of 4: Port"
say "The relay listens only on this machine. The web proxy passes traffic to it."
PORT=8080
while port_busy "$PORT"; do PORT=$((PORT + 1)); done
ask "Local port" "$PORT"
PORT=$REPLY
case "$PORT" in ''|*[!0-9]*) die "the port must be a number" ;; esac

step "3 of 4: Web proxy"
PROXY=none
if active caddy; then PROXY=caddy
elif active nginx; then PROXY=nginx
elif active apache2 || active httpd || active traefik || port_busy 443; then PROXY=other
fi
case "$PROXY" in
caddy) say "Found Caddy. It will get the certificate by itself." ;;
nginx) say "Found Nginx." ; command -v certbot >/dev/null 2>&1 && say "Found certbot: it will get the certificate." || say "certbot is not installed: you add the certificate yourself." ;;
other) say "Something else already serves port 443. You add one proxy rule by hand; it is shown at the end." ;;
none)  say "No web proxy found. Caddy is the simplest choice: it gets the certificate by itself."
	if ! command -v apt-get >/dev/null 2>&1 && ! command -v dnf >/dev/null 2>&1; then
		say "This assistant can install Caddy only with apt or dnf. You add a proxy yourself; the rule is shown at the end."
		PROXY=other
	elif yes_no "Install Caddy now?" y; then PROXY=install-caddy
	else PROXY=other
	fi ;;
esac

step "4 of 4: Check"
say "This will happen on this machine:"
say "  - install the relay to /usr/local/bin/srvmon-relay, as the system user srvmon-relay"
say "  - keep its data in $DATA and its token in $ENV_FILE"
say "  - start it on 127.0.0.1:$PORT and on every boot"
case "$PROXY" in
caddy|install-caddy) say "  - add $DOMAIN to /etc/caddy/Caddyfile" ;;
nginx) say "  - add the Nginx site srvmon-relay.conf for $DOMAIN" ;;
esac
yes_no "Go ahead?" y || { say "Nothing was changed."; exit 0; }

step "Installing"
id srvmon-relay >/dev/null 2>&1 || run "useradd --system --no-create-home --shell /usr/sbin/nologin srvmon-relay"
run "install -m 755 '$HERE/srvmon-relay' /usr/local/bin/srvmon-relay"
run "install -d -o srvmon-relay -g srvmon-relay -m 700 '$DATA'"
TOKEN=""
[ -f "$ENV_FILE" ] && TOKEN=$(sed -n 's/^RELAY_ADMIN_TOKEN=//p' "$ENV_FILE")
if [ -z "$TOKEN" ]; then
	TOKEN=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
fi
if [ -z "$DRY" ]; then
	umask 077
	printf 'RELAY_ADMIN_TOKEN=%s\nRELAY_ADDR=127.0.0.1:%s\nRELAY_DATA=%s\n' "$TOKEN" "$PORT" "$DATA" > "$ENV_FILE"
	umask 022
	cat > "$UNIT" <<UNITEOF
[Unit]
Description=Server Monitor relay
After=network-online.target
Wants=network-online.target

[Service]
User=srvmon-relay
EnvironmentFile=$ENV_FILE
ExecStart=/usr/local/bin/srvmon-relay
Restart=always
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$DATA

[Install]
WantedBy=multi-user.target
UNITEOF
else
	say "  [dry run] write $ENV_FILE and $UNIT"
fi
run "systemctl daemon-reload"
run "systemctl enable srvmon-relay >/dev/null 2>&1"
run "systemctl restart srvmon-relay"

NGINX_RULE="location / {
    proxy_pass http://127.0.0.1:$PORT;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_read_timeout 60s;
    proxy_buffering off;
}"
if [ "$PROXY" = install-caddy ]; then
	if command -v apt-get >/dev/null 2>&1; then run "DEBIAN_FRONTEND=noninteractive apt-get install -y caddy"
	elif command -v dnf >/dev/null 2>&1; then run "dnf install -y caddy"
	fi
	run "systemctl enable --now caddy"
	PROXY=caddy
fi
case "$PROXY" in
caddy)
	if [ -z "$DRY" ] && grep -q "^$DOMAIN " /etc/caddy/Caddyfile 2>/dev/null; then
		say "$DOMAIN is already in the Caddyfile; left as it is."
	elif [ -z "$DRY" ]; then
		cp -p /etc/caddy/Caddyfile /etc/caddy/Caddyfile.srvmon-bak 2>/dev/null || true
		printf '\n%s {\n    reverse_proxy 127.0.0.1:%s {\n        flush_interval -1\n    }\n}\n' "$DOMAIN" "$PORT" >> /etc/caddy/Caddyfile
		caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || {
			[ -f /etc/caddy/Caddyfile.srvmon-bak ] && cp -p /etc/caddy/Caddyfile.srvmon-bak /etc/caddy/Caddyfile
			die "Caddy refused the new config; the old one is back"
		}
		systemctl reload caddy
	else
		say "  [dry run] add $DOMAIN to /etc/caddy/Caddyfile, validate, reload caddy"
	fi ;;
nginx)
	CONF=/etc/nginx/conf.d/srvmon-relay.conf
	if [ -z "$DRY" ]; then
		printf 'server {\n    listen 80;\n    server_name %s;\n    %s\n}\n' "$DOMAIN" "$NGINX_RULE" > "$CONF"
		nginx -t >/dev/null 2>&1 || { rm -f "$CONF"; die "Nginx refused the new site; it was removed again"; }
		systemctl reload nginx
		command -v certbot >/dev/null 2>&1 && { certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect || say "certbot failed: check that DNS points here, then run: certbot --nginx -d $DOMAIN"; }
	else
		say "  [dry run] write $CONF, nginx -t, reload, certbot --nginx -d $DOMAIN"
	fi ;;
other)
	say "Add this to your proxy for https://$DOMAIN (Nginx form; other proxies: see README.md):"
	say "$NGINX_RULE"
	say "Keep the read timeout at 60 s or more and response buffering off."
	ask "Press Enter when the rule is in place" "" ;;
esac

step "Testing"
OK=""
if [ -z "$DRY" ]; then
	curl -fsS --max-time 5 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && say "The relay answers on this machine." || say "The relay does not answer. See: journalctl -u srvmon-relay -n 30"
	i=0
	while [ $i -lt 10 ]; do
		if curl -fsS --max-time 5 "https://$DOMAIN/healthz" >/dev/null 2>&1; then OK=1; break; fi
		i=$((i + 1)); sleep 3
	done
	if [ -n "$OK" ]; then say "https://$DOMAIN answers."; else say "https://$DOMAIN does not answer yet. Check DNS, ports 80 and 443, and the proxy."; fi
fi

step "Done"
say "In the app, open Team and tap Set up relay, then enter:"
say "  Relay address: https://$DOMAIN"
say "  Admin token:   $TOKEN"
say "The token gives full control of the relay. Keep it private."
say "It stays in $ENV_FILE. To move the relay later, see README.md."
