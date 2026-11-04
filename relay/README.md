# srvmon-relay

Lets team members use Server Monitor without SSH and without opening any port on the servers.
Agents connect **out** to the relay (long-poll over HTTPS); member apps talk to the relay.
The relay only routes: each agent checks every request's Ed25519 signature against the member
list that the admin app pushed to it over SSH, and filters containers/logs by role and scope.

## Run (behind your existing reverse proxy)

```bash
cd relay
echo "RELAY_ADMIN_TOKEN=$(openssl rand -base64 36 | tr -d '/+=')" > .env
docker compose up -d --build        # listens on 127.0.0.1:8080
cat .env                            # this token goes into the app: Team › Set up relay
```

Nginx example for `monitor.appinsource.eu` (TLS as for your other sites):

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_read_timeout 60s;   # agents long-poll for 25 s
    proxy_buffering off;
}
```

Caddy (one block, TLS automatic):

```caddy
monitor.appinsource.eu {
    reverse_proxy 127.0.0.1:8080 {
        flush_interval -1
    }
}
```

Traefik (the relay joins the proxy's network; drop the `ports:` line from the compose file):

```yaml
    networks: [traefik]
    labels:
      traefik.enable: "true"
      traefik.http.routers.srvmon-relay.rule: Host(`monitor.appinsource.eu`)
      traefik.http.routers.srvmon-relay.entrypoints: websecure
      traefik.http.routers.srvmon-relay.tls.certresolver: letsencrypt
      traefik.http.services.srvmon-relay.loadbalancer.server.port: "8080"
```

No proxy on the machine yet? Install Caddy (`apt install caddy`), put the block above into
`/etc/caddy/Caddyfile` and `systemctl reload caddy`; it gets the certificate itself.

Whatever the proxy, keep the read timeout at 60 s or more (agents long-poll for 25 s) and
response buffering off.

Check: `curl -s https://monitor.appinsource.eu/healthz` must answer `{"ok":true}`.

## Move to another server

The relay is not tied to its machine. Agents and phones know only the domain, so a move changes
nothing on them. Everything it needs is `.env` (admin token) and `relay.json`.

```bash
# old server, in relay/
./backup.sh                       # stops nothing; writes srvmon-relay-backup-<date>.tgz (mode 600)
docker compose down               # so nothing changes after the copy
scp srvmon-relay-backup-*.tgz root@NEW:/root/

# new server, in relay/ (copy this folder there first)
./restore.sh /root/srvmon-relay-backup-<date>.tgz
docker compose up -d --build
```

Then set up the proxy on the new server, point the domain's DNS at it and check `/healthz`.
Agents reconnect by themselves once DNS has changed. The backup holds the admin token: keep it
private and delete it when the move is done. Lower the DNS TTL a day before to shorten the gap.

Data (servers, members, invites) lives in the `relay-data` volume as `relay.json`; secrets and
tokens are stored only as SHA-256 hashes.
