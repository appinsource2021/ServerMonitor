import Foundation
import Observation
import CryptoKit

/// What the user entered on the Add Server screen.
struct NewServerInput {
    var name = ""
    var host = ""
    var port = 22
    var username = "root"
    var useKey = false          // false = password
    var password = ""
    var privateKeyPEM = ""
    var passphrase = ""
    var switchToAppKey = true   // password mode: install the app key, then forget the password
    var installAgent = true
    var pushAlerts = true
    var watchOthers = true
    var allowActions = true
    /// Continuing a saved draft: same record id, and its auth if the app key is already installed.
    var draftID: UUID?
    var draftAuth: AuthKind?

    init() {}

    init(host: String, username: String) {
        self.host = host
        self.username = username
    }

    /// Prefills from a saved draft, secrets from the Keychain.
    init(draft d: ServerRecord) {
        name = d.name
        host = d.host
        port = d.port
        username = d.username
        draftID = d.id
        draftAuth = d.auth
        useKey = d.auth == .importedKey
        password = Keychain.string(Credentials.passwordKey(d.id)) ?? ""
        privateKeyPEM = Keychain.string(Credentials.privateKeyKey(d.id)) ?? ""
        passphrase = Keychain.string(Credentials.passphraseKey(d.id)) ?? ""
    }

    var usesAppKey: Bool { draftAuth == .appKey }
}

@Observable
@MainActor
final class Installer {
    enum StepState { case pending, running, done, failed, skipped }

    struct Step: Identifiable {
        let id: String
        let title: String
        var detail: String
        var state: StepState = .pending
    }

    var steps: [Step] = []
    var log: [String] = []
    var progress: Double = 0
    var finished = false
    var failedMessage: String?
    var server: ServerRecord?

    private let input: NewServerInput
    private let store: ServerStore
    private var existing: ServerRecord?
    /// Kept across "Try again" so retries update the same draft.
    private var recordID: UUID?
    private var keyInstalled = false

    /// `existing` = re-install/update the agent on a known server.
    init(input: NewServerInput, store: ServerStore, existing: ServerRecord? = nil) {
        self.input = input
        self.store = store
        self.existing = existing
        var s: [Step] = [
            Step(id: "connect", title: "Connect via SSH", detail: "\(input.username)@\(input.host)"),
            Step(id: "check", title: "Check system", detail: "OS, architecture, Docker, systemd"),
        ]
        if existing == nil && !input.useKey && !input.usesAppKey && input.switchToAppKey {
            s.append(Step(id: "key", title: "Install app SSH key", detail: "password will not be stored"))
        }
        let selfUpdate = existing?.externalAgent == true
        s += [
            Step(id: "upload", title: "Upload agent", detail: selfUpdate ? "to the agent's upload folder (SFTP)" : "srvmon-agent + install script"),
            Step(id: "install", title: selfUpdate ? "Agent updates itself" : "Install & start service",
                 detail: selfUpdate ? "checks sha256, swaps the binary, restarts" : "systemctl enable --now srvmon-agent"),
            Step(id: "health", title: "Health check", detail: "srvmon-agent api GET /v1/health"),
            Step(id: "push", title: "Register push alerts", detail: "device token + APNs key"),
        ]
        steps = s
    }

    private func set(_ id: String, _ state: StepState, _ detail: String? = nil) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].state = state
        if let detail { steps[i].detail = detail }
        let done = steps.filter { $0.state == .done || $0.state == .skipped }.count
        progress = Double(done) / Double(steps.count)
    }

    private func out(_ s: String) {
        log.append(contentsOf: s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    /// Starts again after a failure: same input, every step back to pending.
    func retry() async {
        guard failedMessage != nil else { return }
        failedMessage = nil
        finished = false
        for i in steps.indices { steps[i].state = .pending }
        progress = 0
        out("— retrying —")
        await run()
    }

    func run() async {
        var record = existing ?? ServerRecord(
            id: recordID ?? input.draftID ?? UUID(),
            name: input.name.trimmingCharacters(in: .whitespaces),
            host: input.host.trimmingCharacters(in: .whitespaces),
            port: input.port,
            username: input.username.trimmingCharacters(in: .whitespaces),
            auth: (input.usesAppKey || keyInstalled) ? .appKey : input.useKey ? .importedKey : .password
        )
        recordID = record.id
        let isNew = existing == nil
        var current = "connect"
        do {
            // Secrets go to the Keychain before connecting; password is removed later if we switch to the app key.
            if isNew {
                if input.usesAppKey || keyInstalled {
                    // key already on the server from an earlier attempt
                } else if input.useKey {
                    Keychain.setString(input.privateKeyPEM, for: Credentials.privateKeyKey(record.id))
                    if !input.passphrase.isEmpty { Keychain.setString(input.passphrase, for: Credentials.passphraseKey(record.id)) }
                } else {
                    Keychain.setString(input.password, for: Credentials.passwordKey(record.id))
                }
                // Saved right away as a draft: a failed or closed setup keeps everything you typed.
                if let old = store.servers.first(where: { $0.id == record.id }) { record.addedAt = old.addedAt }
                record.installed = false
                store.upsert(record)
            }

            set(current, .running)
            var session = SSHSession(server: record)
            let (who, _) = try await session.run("id -u; uname -n")
            set(current, .done, "\(record.username)@\(record.host) · \(who.split(separator: "\n").last.map(String.init) ?? "")")
            out("$ ssh \(record.username)@\(record.host) — connected")

            current = "check"
            set(current, .running)
            let probe = """
            echo "uid=$(id -u)"
            echo "arch=$(uname -m)"
            . /etc/os-release 2>/dev/null && echo "os=$PRETTY_NAME"
            command -v systemctl >/dev/null && echo "systemd=yes" || echo "systemd=no"
            echo "docker=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo none)"
            command -v sha256sum >/dev/null && echo "sha=yes" || echo "sha=no"
            echo "agent=$( [ -x /usr/local/bin/srvmon-agent ] && /usr/local/bin/srvmon-agent api GET /v1/health 2>/dev/null | head -n1 || echo none)"
            """
            let (info, _) = try await session.run(probe)
            let kv = Dictionary(info.split(separator: "\n").compactMap { line -> (String, String)? in
                let p = line.split(separator: "=", maxSplits: 1).map(String.init)
                return p.count == 2 ? (p[0], p[1]) : nil
            }, uniquingKeysWith: { a, _ in a })
            // Not root: we cannot install anything, but we can use an agent the server's
            // admin set up for this user (socket_group). Otherwise say what is missing.
            let attach = kv["uid"] != "0"
            if attach {
                guard (kv["agent"] ?? "").hasPrefix("HTTP 200") else {
                    throw InstallError("\(record.username) is not root and no agent answered for this user. Log in as root to install the agent, or ask the server's admin to create this monitoring user and install the agent with socket_group (see docs/BRIEFING-monitoring-user.md).")
                }
            }
            guard attach || kv["systemd"] == "yes" else { throw InstallError("systemd was not found on this server.") }
            let arch: String
            switch kv["arch"] ?? "" {
            case "x86_64", "amd64": arch = "amd64"
            case "aarch64", "arm64": arch = "arm64"
            default: throw InstallError("Unsupported CPU architecture: \(kv["arch"] ?? "?")")
            }
            record.arch = arch
            let docker = kv["docker"] ?? "none"
            set(current, .done, [kv["os"] ?? "Linux", kv["arch"] ?? arch, docker == "none" ? "no Docker" : "Docker \(docker)",
                                 attach ? "not root · existing agent" : "systemd"].joined(separator: " · "))
            out(info)

            if keyInstalled {
                set("key", .done, AppIdentity.fingerprint)
            } else if steps.contains(where: { $0.id == "key" }) {
                current = "key"
                set(current, .running)
                let pub = AppIdentity.publicKeyLine
                let script = """
                umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys
                grep -qF \(shq(pub)) ~/.ssh/authorized_keys || printf '%s\\n' \(shq(pub)) >> ~/.ssh/authorized_keys
                """
                let (o, code) = try await session.run(script)
                guard code == 0 else { throw InstallError("Could not add the app key: \(o)") }
                await session.close()
                var keyed = record
                keyed.auth = .appKey
                let test = SSHSession(server: keyed)
                _ = try await test.run("true")
                record = keyed
                session = test
                Keychain.delete(Credentials.passwordKey(record.id))
                keyInstalled = true
                store.upsert(record) // the draft now logs in with the app key
                set(current, .done, AppIdentity.fingerprint)
                out("app key added to authorized_keys; password discarded")
            }

            // Non-root login: a first connect just uses the agent that is there; an update
            // hands the new binary to the agent, which replaces itself (agent ≥ 0.3.6).
            let selfUpdate = attach && existing != nil
            if attach && !selfUpdate {
                set("upload", .skipped, "agent already on the server")
                set("install", .skipped, "managed by the server's admin")
            }

            current = "upload"
            if selfUpdate {
                set(current, .running)
                let (bin, sums, _) = try bundledAgent(arch: arch)
                let expected = try expectedHash(sums: sums, arch: arch)
                let actual = SHA256.hash(data: bin).map { String(format: "%02x", $0) }.joined()
                guard actual == expected else { throw InstallError("Bundled agent checksum mismatch.") }
                let api = AgentAPI(session: session)
                let tooOld = InstallError("Agent \(record.agentVersion ?? "?") cannot update itself. Update it on the server once (README › Agent'ı güncellemek); from 0.3.6 on, updates work from here.")
                struct Slot: Decodable { let temp: String }
                let slot: Slot
                do {
                    slot = try JSON.decoder.decode(Slot.self, from: try await api.post("/v1/fs/upload"))
                } catch let e as AgentAPI.HTTPError where e.status == 404 {
                    throw tooOld
                }
                let total = bin.count
                try await session.upload(bin, to: slot.temp) { [weak self] p in
                    Task { @MainActor in
                        self?.set("upload", .running, "srvmon-agent · \(Fmt.bytes(UInt64(Double(total) * p))) / \(Fmt.bytes(UInt64(total)))")
                    }
                }
                set(current, .done, "srvmon-agent · \(Fmt.bytes(UInt64(total))) · sha256 \(expected.prefix(12))…")

                current = "install"
                set(current, .running, "the agent checks the file, swaps itself and restarts")
                struct Up: Encodable { let temp: String; let sha256: String }
                struct UpResult: Decodable { let to: String }
                let res: UpResult
                do {
                    res = try JSON.decoder.decode(UpResult.self, from: try await api.send("POST", "/v1/agent/update", Up(temp: slot.temp, sha256: expected), timeout: .seconds(90)))
                } catch let e as AgentAPI.HTTPError where e.status == 404 {
                    throw tooOld
                }
                out("agent accepted \(res.to); restarting")
                // It restarts about two seconds later; wait until the new version answers.
                var seen = ""
                for i in 0..<45 {
                    try? await Task.sleep(for: .seconds(1))
                    set(current, .running, "waiting for \(res.to) to come back · \(i + 1) s")
                    if let h: AgentHealth = try? await api.get("/v1/health", timeout: .seconds(15)) {
                        seen = h.version
                        if h.version == res.to { break }
                    }
                }
                guard seen == res.to else {
                    throw InstallError("The agent did not come back as \(res.to) (last seen: \(seen.isEmpty ? "no answer" : seen)). On the server: systemctl status srvmon-agent; the old binary is kept as srvmon-agent.prev.")
                }
                set(current, .done, "restarted as \(res.to)")
            } else if !attach {
            set(current, .running)
            let (bin, sums, installSh) = try bundledAgent(arch: arch)
            let expected = try expectedHash(sums: sums, arch: arch)
            let actual = SHA256.hash(data: bin).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw InstallError("Bundled agent checksum mismatch.") }
            _ = try await session.run("rm -rf /tmp/srvmon-install && mkdir -m 700 /tmp/srvmon-install")
            try await session.upload(installSh, to: "/tmp/srvmon-install/install.sh")
            let cfg: [String: Any] = ["name": record.name, "allow_actions": input.allowActions]
            try await session.upload(try JSONSerialization.data(withJSONObject: cfg), to: "/tmp/srvmon-install/config.json")
            let total = bin.count
            try await session.upload(bin, to: "/tmp/srvmon-install/srvmon-agent") { [weak self] p in
                Task { @MainActor in
                    self?.set("upload", .running, "srvmon-agent · \(Fmt.bytes(UInt64(Double(total) * p))) / \(Fmt.bytes(UInt64(total)))")
                }
            }
            if kv["sha"] == "yes" {
                let (h, _) = try await session.run("sha256sum /tmp/srvmon-install/srvmon-agent | cut -d' ' -f1")
                guard h.trimmingCharacters(in: .whitespacesAndNewlines) == expected else { throw InstallError("Upload corrupted (checksum mismatch).") }
            }
            set(current, .done, "srvmon-agent · \(Fmt.bytes(UInt64(total))) · sha256 OK")

            current = "install"
            set(current, .running)
            let (io, icode) = try await session.run("(chmod 700 /tmp/srvmon-install/srvmon-agent && sh /tmp/srvmon-install/install.sh /tmp/srvmon-install/srvmon-agent /tmp/srvmon-install/config.json; rc=$?; rm -rf /tmp/srvmon-install; exit $rc)")
            out(io)
            guard icode == 0 else { throw InstallError(io.split(separator: "\n").last.map(String.init) ?? "install failed") }
            set(current, .done, "listening on /run/srvmon/agent.sock")
            }

            current = "health"
            set(current, .running)
            let api = AgentAPI(session: session)
            let h: AgentHealth = try await api.get("/v1/health")
            record.agentVersion = h.version
            record.installed = true
            record.externalAgent = attach ? true : nil
            set(current, .done, "srvmon-agent \(h.version) OK" + (attach ? " · as \(record.username)" : ""))

            // Saved from here on: the server is usable even if push setup fails.
            store.upsert(record)
            server = record

            current = "push"
            set(current, .running)
            if input.pushAlerts {
                var parts: [String] = []
                if PushSettings.configured { try await store.deployAPNs(to: record); parts.append("APNs key") }
                if store.deviceToken != nil { try await store.registerDevice(on: record); parts.append("this iPhone") }
                set(current, parts.isEmpty ? .skipped : .done,
                    parts.isEmpty ? "add your APNs key in Settings to enable" : parts.joined(separator: " + ") + " registered")
            } else {
                set(current, .skipped, "turned off")
            }
            if input.watchOthers { await store.syncPeers() }
            finished = true
            Task { await store.refresh(record) }
        } catch {
            let msg = friendlyError(error)
            set(current, .failed, msg)
            failedMessage = msg
            out("ERROR: \(error)")
        }
    }

    private func bundledAgent(arch: String) throws -> (Data, String, Data) {
        guard let dir = Bundle.main.url(forResource: "Agent", withExtension: nil) else { throw InstallError("Agent files missing from the app bundle.") }
        let bin = try Data(contentsOf: dir.appendingPathComponent("srvmon-agent-linux-\(arch)"))
        let sums = try String(contentsOf: dir.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        let sh = try Data(contentsOf: dir.appendingPathComponent("install.sh"))
        return (bin, sums, sh)
    }

    private func expectedHash(sums: String, arch: String) throws -> String {
        for line in sums.split(separator: "\n") {
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            if p.count == 2, p[1].hasSuffix("srvmon-agent-linux-\(arch)") { return String(p[0]) }
        }
        throw InstallError("No checksum for \(arch).")
    }
}

struct AgentHealth: Decodable {
    let ok: Bool
    let version: String
}

extension ServerRecord {
    /// The app can replace the agent: as root through the installer, or, for a non-root
    /// login, through the agent's own update route (agent ≥ 0.3.6).
    var canUpdateFromApp: Bool {
        if isRelay { return false }
        if managesAgent { return true }
        return BundledAgent.compare(agentVersion ?? "0", "0.3.6") >= 0
    }
}

struct InstallError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// The agent version packaged with this build (`make ios-resources` writes Resources/Agent/VERSION).
enum BundledAgent {
    static let version: String = {
        guard let dir = Bundle.main.url(forResource: "Agent", withExtension: nil),
              let s = try? String(contentsOf: dir.appendingPathComponent("VERSION"), encoding: .utf8) else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    /// The one-file relay installer (`relay/make-release.sh`), shared from Team → Set up relay.
    static var relayInstallerURL: URL? {
        guard let dir = Bundle.main.url(forResource: "Agent", withExtension: nil) else { return nil }
        let url = dir.appendingPathComponent("srvmon-relay-setup.sh")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func binaryURL(arch: String) -> URL? {
        guard let dir = Bundle.main.url(forResource: "Agent", withExtension: nil) else { return nil }
        let url = dir.appendingPathComponent("srvmon-agent-linux-\(arch)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// sha256 of the bundled binary for an architecture, from SHA256SUMS.
    static func sha256(arch: String) -> String? {
        guard let dir = Bundle.main.url(forResource: "Agent", withExtension: nil),
              let sums = try? String(contentsOf: dir.appendingPathComponent("SHA256SUMS"), encoding: .utf8) else { return nil }
        for line in sums.split(separator: "\n") {
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            if p.count == 2, p[1].hasSuffix("srvmon-agent-linux-\(arch)") { return String(p[0]) }
        }
        return nil
    }

    /// true when the server's agent is older than the bundled one ("0.3.2" < "0.3.3").
    static func isOutdated(_ server: String?) -> Bool {
        guard let server, !server.isEmpty, !version.isEmpty else { return false }
        return compare(server, version) < 0
    }

    static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { part in Int(part.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }
}
