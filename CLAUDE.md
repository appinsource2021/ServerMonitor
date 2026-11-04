# ServerMonitor — notes for Claude Code

The owner is Suleyman (appinsource). Talk to him in **Turkish**. Keep code, identifiers and UI strings in English.
The user-facing README (`README.md`) is in Turkish. Update it whenever a feature or a fix changes how the app is used.

**Product decisions live in `docs/URUN-YOL-HARITASI.md`. Read it before planning work, and write every new decision there first.**

## Brand rule (strict)
- Always write **appinsource**, all lowercase. Never "AppInSource" or "Appinsource".
- In the UI, use `BrandWordmark` (`ios/ServerMonitor/UI/Brand.swift`):
  - "app" and "source": white in dark mode, black in light mode.
  - "in": `#009CDE` (PayPal blue) in dark mode, `#0070BA` in light mode.

## What this is
An iOS app that monitors several dedicated Linux servers. It has three parts:
- `agent/` — Go daemon `srvmon-agent` that runs as root under systemd.
  - Listens only on the unix socket `/run/srvmon/agent.sock`, so **no ports are opened**.
  - The app reaches it over SSH by running `srvmon-agent api METHOD PATH [BODY]`, which prints `HTTP <code>\n<body>`.
  - Features: metrics, Docker (Engine API over its unix socket), systemd and journal, alerts, APNs push, peer checks, health check, disk scan, smart cleanup, and team members (Ed25519-signed requests).
- `relay/` — Go relay for team members, so that no server ports have to be opened. Agents long-poll it outbound. It is **not deployed yet**; the planned address is https://monitor.appinsource.eu.
- `ios/` — SwiftUI app (iOS 17).
  - Packages: Citadel (SSH) and SwiftTerm (terminal).
  - Shared state lives in `@Observable ServerStore`.
  - `AgentAPI` talks to the agent over SSH, or through the relay for team members.
- `e2e/` — separate Go module with relay and agent end-to-end tests. Run it from inside `e2e/`.

## Build and test
```sh
# agent
cd agent && go vet ./... && go test ./...
make ios-resources     # builds linux amd64/arm64 + SHA256SUMS into ios/ServerMonitor/Resources/Agent/
# ^ Resources/Agent/ is gitignored. On a fresh clone, run this (needs Go) before the first Xcode build.
cd ../e2e && go test ./...

# iOS: after adding or removing a .swift file, regenerate the Xcode project
python3 tools/mkproj.py ios
# build to the iPhone in Release (scheme LaunchAction is Release)
xcodebuild -project ios/ServerMonitor.xcodeproj -scheme ServerMonitor -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates build
# or simply press Run in Xcode
```

## Project generator
- `tools/mkproj.py` writes `project.pbxproj`, the scheme, `Info.plist` and the entitlements.
- `ios/project.yml` is **outdated**; do not use xcodegen.
- Settings that live in `mkproj.py`:
  - Team `3DML5X8547` (personal team).
  - Bundle ID `eu.appinsource.servermonitor`.
  - `MARKETING_VERSION` 0.3.0, build 3.
  - URL scheme `srvmon`.
- Package pins:
  - Citadel: up to next minor from 0.12.0.
  - SwiftTerm: **exactly 1.10.1**. Newer versions need the Metal toolchain and a build plugin.
- Entitlements stay **empty**. A personal Apple team cannot use Push Notifications, so APNs stays unused until there is a paid team.

## Versions
- The agent version is in `agent/main.go` (`var version`) and in `agent/Makefile` (`VERSION ?=`). It is **0.4.1** now.
- After agent changes:
  1. Bump both places.
  2. Run `make ios-resources`.
  3. The bundled binary ships with the app.
  4. On each server, run ··· → **Update agent** in the app. The installer keeps `/etc/srvmon/config.json` on updates.
  5. `make ios-resources` also writes `Resources/Agent/VERSION`; `BundledAgent` (Installer.swift) reads it and the server list shows a yellow **Update now** strip on every card whose agent is older.

## Conventions and gotchas
- Every SSH call has a deadline (`SSHSession.run(_, timeout:)`, `AgentAPI.raw(..., timeout:)`, default 90 s).
  - On timeout the connection is dropped and rebuilt.
  - A dead connection used to hang the UI forever, so never add an un-timed await on SSH.
- Long agent jobs (disk scan, cleanup) run in the background on the agent and are polled by the app. Each one must have a server-side limit and a cancel route.
  - Child processes go through `killableCmd` (own process group plus `WaitDelay`).
- Container actions are blocked when `allow_actions=false` in the agent config. The app offers "Turn on container actions".
- Team members (relay) never see logs unless they are admins. Scopes are globs over container name, image or compose project.
- Server 217.160.39.208 (the MCP dev server) has root login gated by TOTP plus a dashboard window.
  - Solved 2026-11-03: the `srvmon` user and agent 0.3.5 with `socket_group "srvmon"` are on 208 (script from the app, run as root in an admin window); the app connects as `srvmon` with the iPhone key ("Romon MCP"). Agent updates there: scp the binary to `/tmp/srvmon-agent`, run the script again.
  - Lesson: login attempts made before the user existed got the phone's IP banned by fail2ban ("Connection refused"); `fail2ban-client set sshd unbanip <ip>` fixed it. Tell the user not to retry repeatedly.
  - The whole episode (four things that went wrong, fixes, checklist) is written up for Suleyman in `docs/SENARYO-srvmon-kurulum-ve-guncelleme.md`; he wants to solve such things from the docs without Claude. Keep it and `docs/SRVMON-USER.md` current when the flow changes.
  - App side: see "Non-root servers" below.
- Destructive actions on a real server need Suleyman's explicit OK.

## File manager (agent 0.3.3, `agent/fs.go`)
- Routes, admin over SSH only (HandleMember never routes `/v1/fs`, so relay members get 403):
  - `GET /v1/fs/list?path=` — entries with type, size, mtime, owner, mode, symlink target and `in_use`.
  - `GET /v1/fs/read?path=` — text only (binary detected), up to 512 KB, tail for bigger files; `sha256` and `editable` only when the file can be edited.
  - `PUT /v1/fs/write` `{path, content, expect_sha256, create}` — 409 on a hash mismatch, backup `file.srvmon-bak-<ts>` (3 kept), atomic write keeping mode and owner, writes through symlinks.
  - `DELETE /v1/fs?path=&force=1` — recursive, returns `freed_bytes`; 409 when in use unless `force`; refuses mount points.
  - `POST /v1/fs/mkdir` `{path}` — 409 if it exists, parent must exist.
  - `POST /v1/fs/upload` — returns `{temp}` under `/var/lib/srvmon/upload/` (not `/tmp`: the unit has `PrivateTmp`); the app writes it over SFTP. Stale uploads older than a day are pruned.
  - `POST /v1/fs/import` `{temp, path, overwrite}` — moves the upload into place (rename, copy across filesystems), 409 if the name exists unless `overwrite` (then backup, mode and owner kept).
- Limits: edit up to **64 KB** (the content travels as one SSH command-line argument), 2000 entries per listing.
- Deny list (write and delete, subtrees included): `/`, `/proc`, `/sys`, `/dev`, `/boot`, `/usr`, `/bin`, `/sbin`, `/lib*`, `/etc/srvmon`, `/usr/local/bin/srvmon-agent`, `/run/srvmon`. Delete also refuses every top-level directory and `/var/lib/docker`. `/proc`, `/sys`, `/dev` are not even listed.
- `in_use` = bind mount of a container or working directory of a process (same idea as `protectedPaths` in `cleanup.go`).
- iOS: `DiskUsageView` is a `List` (swipe or long-press to delete, `DeleteSheet` asks to type a folder's name; the `+` menu creates files and folders and uploads from the Files app over SFTP). `FileEditorView` views (line numbers, find), edits and saves; a 409 offers reload or overwrite.
- Tests: `agent/fs_test.go` covers the deny list, listing, tail reads, conflict, backup, atomic write, delete and the relay 403.

## Agent self-update (agent 0.3.6, `agent/update.go`)
- `POST /v1/agent/update {temp, sha256}`: `temp` must come from `POST /v1/fs/upload`; the agent checks the sha256, runs `<temp> version` (must look like a version), keeps the old file as `<path>.prev`, swaps with install + rename and schedules `systemctl restart srvmon-agent` two seconds later. Swap and restart run through `systemd-run` (transient units) because the service's `ProtectSystem=full` makes `/usr` read-only; without systemd-run it does the swap in-process. Relay members get 403 (not in the allowlist). Tests: `agent/update_test.go`.
- iOS: `Installer` with `existing.externalAgent == true` takes this path (upload over SFTP to the slot as the login user, call the route, poll `/v1/health` until the new version answers, 45 s). `ServerRecord.canUpdateFromApp` = root-managed, or non-root with agent ≥ 0.3.6; it gates Update now and ··· → Update agent. Older non-root agents still need the manual script once (README § 11).

## Non-root servers (app 0.3.5, "attach" mode)
- `ServerRecord.externalAgent == true` marks a server the app logs into as a non-root user; `managesAgent` is false then (also for relay servers).
- `Installer.run`: the probe also runs `srvmon-agent api GET /v1/health` as the login user. uid ≠ 0 and `HTTP 200` → attach: upload/install steps are skipped, health is checked, the record is saved with `externalAgent`. uid ≠ 0 without an answering agent → error naming the briefing. Root behaves as before.
- Hidden for such servers: ··· → Update agent, "Remove and uninstall agent", and the button on the yellow update strip (the strip only says to update on the server).
- `AddServerView`: a non-root User shows a banner, hides the "Container actions" toggle (the config is the admin's) and the button reads "Connect to existing agent". Its "Server setup script" button opens `MonitoringSetupView` (`UI/MonitoringSetupView.swift`): arch picker, `ShareLink` of the bundled binary plus the scp command, and the script from `MonitoringSetupScript.make` with the iPhone key, user, server name and the binary's sha filled in (copy or share as `srvmon-setup.sh`). The script is the one in `docs/BRIEFING-monitoring-user.md` §6, parameterised; keep the two in step.
- `BundledAgent.binaryURL(arch:)` and `sha256(arch:)` read the bundle for that sheet.
- Agent 0.3.5: `fsPrepareUploadDir` makes `/var/lib/srvmon/upload` `root:<socket_group> 0770` so the SSH user can write uploads over SFTP (0.3.7 also makes the parent `/var/lib/srvmon` `root:<group> 0750`, without which SFTP never reached the folder); `fsImport` gives a new file the owner of its folder (an upload by `srvmon` no longer lands as `srvmon`).
- Everything else (health check, disk, file manager, terminal, relay enrol) goes through the agent API or the user's own shell and works unchanged. The agent runs as root, so the non-root key holder has the full API, file edits included.

## Second iPhone (phone-to-phone authorization)
- `Services/PhoneLinks.swift`: `srvmon://authorize?k=<key line>&n=<device>` (new phone shows it as a QR in Settings → This iPhone's SSH key, `PhoneKeyCard`) and `srvmon://import?s=<base64url JSON [{n,h,p,u,x}]>` (the connected phone hands over its server list). Both are opened through the Camera app or a shared link; `RootView.onOpenURL` routes them to `store.pendingAuthorize` / `store.pendingImport`, join links as before.
- `AuthorizePhoneView` (connected phone): picks servers, `store.authorize(key:on:)` appends the key to the login user's own `~/.ssh/authorized_keys` over SSH (root's or srvmon's, no root needed for the latter), remembers the phone in `store.authorizedPhones` (UserDefaults `phones.v1`), then shows the import QR. `ImportServersView` (new phone): `store.importServers` creates records with `auth: .appKey`, `installed: true`, `externalAgent` carried over; nothing is installed.
- Settings → Other iPhones (`AuthorizedPhonesSection`): list with Revoke (`store.revoke`, removes the key line on every server it was put on, never this phone's own key) and a paste field for a key.
- `PhoneLink.validKey` accepts only `ssh-ed25519 <51-byte blob> [plain comment]`; the line reaches the shell through `shq` only.

## Server screen (agent 0.3.4)
- `ServerDetailView` no longer has Containers/Services tabs. Below the CPU chart sit two cards:
  - `DockerCard` (`UI/ContainersScreen.swift`) → `ContainersScreen`: engine state, running/stopped/problems/images, the containers' total CPU (share of the host) and memory, and a last-hour chart of container CPU against host CPU. The screen lists the containers with the filter; its first row is `docker.service` with the engine's journal.
  - `ServicesCard` (`UI/ServicesScreen.swift`) → `ServicesScreen`: every systemd unit except `docker.service` ("Other services"). Hidden for relay members without log access, as the tab was.
- Agent side: `Snapshot.docker` (`DockerInfo`: version, images, storage driver, data root; from `GET /info`, refreshed once a minute) and `HistoryPoint.docker_cpu` / `docker_mem` (`dockerLoad` in `docker.go`, running containers only, CPU divided by the host's CPU count). Relay members get neither (`summaryFor` strips them).
- Child screens run their own 5-second refresh loop: a `.task` on the server screen is cancelled while a pushed screen covers it.
- The filter helper is `TextFilter.matches` (moved out of `ServerDetailView`).

## Website (`official/`, 2026-11-03)
- Static promo site in English, no build step, no external requests (no Google Fonts: GDPR; no analytics, no cookies). Files: `index.html`, `srvmon-user.html` (English `docs/SRVMON-USER.md`), `privacy.html`, `assets/site.css`, `assets/site.js`, `assets/img/`.
- Planned home `https://monitor.appinsource.eu/`, same host as the relay: site at `/`, relay routes proxied. Caddy and Nginx snippets in `official/README.md`. Preview: `python3 -m http.server -d official 8000`.
- Colors mirror `Theme.swift`; the brand wordmark is `.wordmark` (`in` blue). The mock screens (`.app`) always keep the app's dark look. Status is shown by shape and color, as in the app.
- CTA is `mailto:developer@appinsource.eu` ("Request access") until the app is on the App Store. No version numbers on the pages.
- The steps in `srvmon-user.html` must match `MonitoringSetupView` and `MonitoringSetupScript.make`; change all three together.

## Services (agent 0.4.0)
- `POST /v1/services/{name}/{action}` (start, stop, restart) in `agent/systemd.go` `serviceAction`: gated by `allow_actions` like containers, admin over SSH only (HandleMember never routes it). Never touched: `srvmon-agent.service`; never stopped or restarted: `ssh`/`sshd`, `systemd-logind`, `dbus` (start is allowed). `systemctlRun` is swapped in tests (`agent/services_test.go`). After the action the agent re-collects the unit list so the app sees the new state at once.
- iOS: `Model/KnownServices.swift` is the catalogue (Nginx, Apache, Caddy, MySQL/MariaDB, PostgreSQL, Redis, PHP-FPM, Docker, SSH, fail2ban …) matched on the unit-name prefix; `Snapshot.knownServices`. `ServicesCard` shows them as chips, `ServicesScreen` lists them first under "Known services", every row opens `UI/ServiceDetailView.swift` (state, Start/Stop/Restart with confirm, journal). Actions are gated by `Feature.serviceActions`; a 404 from an older agent says to update it. The ··· menu switch is now "Container & service actions…" (same `allow_actions` flag).

## Processes (agent 0.4.1, `agent/processes.go`)
- `GET /v1/processes`: two `/proc` samples one second apart. `cpu_percent` is the share of the whole host (process ticks over the host's total ticks, like the CPU gauge). Returns the top 60 by CPU plus the top 60 by memory, and `total`. Kernel threads are left out; `container` comes from the process's cgroup.
- Admin over SSH only: command lines can hold passwords, so HandleMember never routes it (`processes_test.go`). Read only, no kill yet.
- iOS: `UI/ProcessesScreen.swift`, opened from the Processes button under Health check and Terminal. Own 5-second loop, CPU/Memory sort, filter, tap a row for the full command. Not plan-gated (watching is free). A 404 shows "needs agent 0.4.1".

## Plans (app 0.4.0, `Services/Plan.swift`, `UI/PlanView.swift`)
- `Feature` lists everything a plan can lock; `PlanConfig` holds the numbers (`trialDays` 14, `freeServerLimit` 1, `freeFeatures` empty = Free is watch only, `purchasesEnabled` **false**).
- `PlanStore.shared.plan` is `.pro` while `purchasesEnabled` is false, so nothing is locked today. StoreKit sets `purchased` later. The trial start date is in the Keychain (`plan.trialStarted`); `simulated` (UserDefaults `plan.simulated`) is the Settings → Plan → Simulate switch.
- Gates: screens ask `plans.allows(.x)` and open `PlanSheet(reason:)` when locked. Gated today: add server beyond the limit (`ServerListView.addServer`), Terminal and Disk (`ServerDetailView`), Smart cleanup (`DiskUsageView`), container buttons (`ContainerDetailView.actionButton`), push section (`SettingsView`), Team tab (`RootView` → `PlanLockedScreen`). New features (service actions, service install) must go through the same check.
- Decided 2026-11-03 with Suleyman: Free = 1 server, watch only; Trial = 14 days, every feature but still 1 server (`serverLimit` is nil only on Pro; servers already in the list are never removed); Pro by server-count tiers or a one-time unlock, numbers still open. README § 13.

## Open work
1. Deploy the relay. Decided 2026-11-04: for now in Suleyman's MCP workspace as a project (not on the host: the MCP server forbids that, and its host tools need a dashboard window), must stay movable. Steps: `docs/URUN-YOL-HARITASI.md` § 4, zip from `relay/make-workspace-zip.sh`.
2. Fix the Swift 6 concurrency warnings in `TerminalScreen.swift` (they do not break the build).
3. File manager follow-ups if wanted: rename/move, download to the phone, edit files over 64 KB (would need SFTP for the content).
4. Relay setup assistant inside the app (Team → Set up relay → "Install on one of my servers"): SSH in like the agent installer, relay as a single Go binary under systemd, Caddy (or an existing Nginx vhost) for TLS on the domain, token generated and saved automatically, DNS checked. Suleyman asked for this on 2026-11-02.
5. Promo website: built in `official/` (see "Website" above). Deployment waits for the relay host (item 1); an OG image and a Turkish page are open.
6. The `srvmon` user explanation is published: `docs/SRVMON-USER.md` (Turkish), `official/srvmon-user.html` (English, website) and `MonitoringSetupView` (app). Keep the three in step.
7. Consider making `srvmon` the login the app keeps even after a root install (the installer would create the user and switch the record to it, so the app never holds root). Agent self-update exists since 0.3.6; Terminal would run as `srvmon` then.

8. Agent for macOS and Windows. Suleyman (2026-11-04) wants both, Mac first, as a separate Mac program that connects out to the relay and pairs by key (roadmap § 6). The agent is Linux only today: metrics read `/proc`, the installer needs systemd, `make` builds linux binaries. Needs per-OS collectors behind one interface, launchd (macOS) and a Windows service, and a different install path on each. Not started; it needs a decision on priority.
9. Management tool: a web panel, next to the website, where the relay's server is chosen (roadmap § 5). Scope still to be discussed.
10. Next in the app: 24-hour history, iPad, service install catalogue, demo server.

## Folder notes
- `_old/` holds the zips that were used to sync from a cloud session. It is safe to delete.
