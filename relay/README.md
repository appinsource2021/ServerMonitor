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

Data (servers, members, invites) lives in the `relay-data` volume as `relay.json`; secrets and
tokens are stored only as SHA-256 hashes.
