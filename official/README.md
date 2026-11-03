# official/ — the Server Monitor website

Static site, no build step: `index.html`, `srvmon-user.html`, `privacy.html`, `assets/site.css`, `assets/site.js`, `assets/img/`.
It makes no request to any other host (no fonts, no analytics), so it needs no cookie banner.

## Preview

```sh
python3 -m http.server -d official 8000      # http://localhost:8000
```

## Deploy

Planned home: `https://monitor.appinsource.eu/`, the same host as the relay. The site is served at `/`;
the relay's routes (`/admin/*`, `/m/*`, `/agent/*`, `/healthz`) are proxied to the relay on `127.0.0.1:8080`
(see `relay/README.md`). Copy this folder to the server, for example to `/srv/official`.

Caddy:

```
monitor.appinsource.eu {
    root * /srv/official
    @api path /admin/* /m/* /agent/* /healthz
    reverse_proxy @api 127.0.0.1:8080 {
        flush_interval -1          # agents long-poll for 25 s
    }
    file_server
}
```

Nginx (TLS as for your other sites):

```nginx
root /srv/official;
location / { try_files $uri $uri/ =404; }
location ~ ^/(admin|m|agent)/|^/healthz$ {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_read_timeout 60s;
    proxy_buffering off;
}
```

## Rules

- English. Brand always lowercase: **appinsource**, with only "in" in blue (`.wordmark`).
- Colors follow the app (`ios/ServerMonitor/UI/Theme.swift`); the mock screens inside `.app` always keep the app's dark look.
- `srvmon-user.html` is the English version of `docs/SRVMON-USER.md`. The steps must match `MonitoringSetupView` and
  `MonitoringSetupScript.make` in the app; change all three together.
- The call to action is the `mailto:` link to developer@appinsource.eu (three places in `index.html`, one in each other page's
  header). Replace it with the App Store link when the app ships.
- No version numbers on the pages, so they do not go stale.
