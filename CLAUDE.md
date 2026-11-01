# ServerMonitor — notes for Claude Code

The owner is Suleyman (appinsource). Talk to him in **Turkish**. Keep code, identifiers and UI strings in English.
The user-facing README (`README.md`) is in Turkish. Update it whenever a feature or a fix changes how the app is used.

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
- The agent version is in `agent/main.go` (`var version`) and in `agent/Makefile` (`VERSION ?=`). It is **0.3.3** now.
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
  - Plan: a non-root `srvmon` user with `socket_group "srvmon"`; see `docs/BRIEFING-monitoring-user.md`.
  - The app does not yet have a mode for "connect as non-root to an existing agent" (promised, still to do).
  - The sha in the briefing refers to the old 0.2.1 binary.
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

## Open work
1. Non-root connect mode for 208 (see above).
2. Deploy the relay; Suleyman has not yet decided where it runs.
3. Fix the Swift 6 concurrency warnings in `TerminalScreen.swift` (they do not break the build).
4. File manager follow-ups if wanted: rename/move, download to the phone, edit files over 64 KB (would need SFTP for the content).

## Folder notes
- `_old/` holds the zips that were used to sync from a cloud session. It is safe to delete.
