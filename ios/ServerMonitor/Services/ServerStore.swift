import Foundation
import Observation
import UIKit
import SwiftUI

struct ServerState {
    var summary: Summary?
    var error: String?
    var lastUpdate: Date?
    var loading = false

    var health: Health {
        if summary == nil { return error == nil ? .unknown : .offline }
        if error != nil, let last = lastUpdate, Date().timeIntervalSince(last) > 60 { return .offline }
        return Health(rawValue: summary?.status.level ?? "") ?? .unknown
    }
}

@Observable
@MainActor
final class ServerStore {
    var servers: [ServerRecord] = []
    var states: [UUID: ServerState] = [:]
    var deviceToken: String?
    /// Set when a notification is tapped; the list navigates to it.
    var openServerName: String?
    /// Non-nil when this iPhone is a team member (no SSH, everything through the relay).
    var member: MemberAccount? = MemberAccount.load()
    var memberActivated = true
    let team = TeamStore()
    /// A srvmon://join link that was opened and waits for confirmation.
    var pendingJoin: TeamJoin.Link?

    var isAdmin: Bool { member == nil }
    var canAct: Bool { member?.canAct ?? true }
    var seesLogs: Bool { member?.seesLogs ?? true }
    var sshServers: [ServerRecord] { servers.filter { !$0.isRelay } }

    @ObservationIgnored private var sessions: [UUID: SSHSession] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private let saveKey = "servers.v1"

    init() { load() }

    // MARK: persistence

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: saveKey),
              let list = try? JSONDecoder().decode([ServerRecord].self, from: d) else { return }
        servers = list
    }

    private func save() {
        if let d = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(d, forKey: saveKey) }
    }

    func upsert(_ s: ServerRecord) {
        if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i] = s } else { servers.append(s) }
        sessions[s.id] = nil
        save()
    }

    func remove(_ s: ServerRecord, uninstall: Bool) async {
        if uninstall {
            _ = try? await session(for: s).run("systemctl disable --now srvmon-agent; rm -f /etc/systemd/system/srvmon-agent.service /usr/local/bin/srvmon-agent; rm -rf /etc/srvmon; systemctl daemon-reload")
        }
        await sessions[s.id]?.close()
        sessions[s.id] = nil
        Credentials.removeAll(for: s.id)
        servers.removeAll { $0.id == s.id }
        states[s.id] = nil
        save()
        await syncPeers()
    }

    // MARK: sessions

    func session(for s: ServerRecord) -> SSHSession {
        if let x = sessions[s.id] { return x }
        let x = SSHSession(server: s)
        sessions[s.id] = x
        return x
    }

    func api(for s: ServerRecord) -> AgentAPI {
        if s.isRelay, let m = member, let rid = s.relayServerID {
            return AgentAPI(relay: RelayClient(baseURL: m.relayURL, bearer: MemberAccount.token), serverID: rid)
        }
        return AgentAPI(session: session(for: s))
    }

    /// Drops the SSH connection and connects again (after Wi-Fi changes, server reboots…).
    func reconnect(_ s: ServerRecord) async {
        if let x = sessions[s.id] { await x.close() }
        sessions[s.id] = nil
        await refresh(s)
    }

    func server(named name: String) -> ServerRecord? { servers.first { $0.name == name } }

    var sortedServers: [ServerRecord] {
        servers.sorted {
            let a = states[$0.id]?.health.rank ?? 3, b = states[$1.id]?.health.rank ?? 3
            return a == b ? $0.name < $1.name : a < b
        }
    }

    var counts: (healthy: Int, warning: Int, critical: Int) {
        var h = 0, w = 0, c = 0
        for s in servers {
            switch states[s.id]?.health ?? .unknown {
            case .healthy: h += 1
            case .warning: w += 1
            case .critical, .offline: c += 1
            case .unknown: break
            }
        }
        return (h, w, c)
    }

    var allActiveAlerts: [AgentAlert] {
        var seen = Set<String>()
        var out: [AgentAlert] = []
        for s in servers {
            for a in states[s.id]?.summary?.alerts ?? [] where seen.insert(a.server + a.key).inserted {
                out.append(a)
            }
            if states[s.id]?.health == .offline {
                let key = "offline"
                if seen.insert(s.name + key).inserted {
                    out.append(AgentAlert(key: key, server: s.name, severity: "critical", title: "Not reachable from this iPhone",
                                          message: states[s.id]?.error ?? "", container: nil, service: nil,
                                          since: ISO8601DateFormatter().string(from: states[s.id]?.lastUpdate ?? .now),
                                          resolved: nil, notified: false))
                }
            }
        }
        return out.sorted { $0.health.rank < $1.health.rank }
    }

    // MARK: polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        let all = sessions.values
        Task { for s in all { await s.close() } }
    }

    @ObservationIgnored private var lastTeamSync = Date.distantPast

    func refreshAll() async {
        if member != nil {
            await refreshMembership()
        } else if RelaySettings.configured, Date().timeIntervalSince(lastTeamSync) > 30 {
            // admin: activate members who joined since last time
            lastTeamSync = .now
            await team.load()
            if team.state?.members.contains(where: \.needsSync) == true { await team.sync(store: self) }
        }
        await withTaskGroup(of: Void.self) { g in
            for s in servers where s.installed {
                g.addTask { await self.refresh(s) }
            }
        }
    }

    func refresh(_ s: ServerRecord) async {
        // Only the very first load shows a spinner; later refreshes swap data in one write,
        // otherwise every poll redraws the screen twice and it visibly "breathes".
        if states[s.id]?.summary == nil, states[s.id]?.loading != true {
            states[s.id, default: ServerState()].loading = true
        }
        do {
            let sum: Summary = try await api(for: s).get("/v1/summary")
            var st = states[s.id] ?? ServerState()
            st.summary = sum
            st.error = nil
            st.lastUpdate = .now
            st.loading = false
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { states[s.id] = st }
            if let i = servers.firstIndex(where: { $0.id == s.id }),
               servers[i].agentVersion != sum.snapshot.host.agentVersion || servers[i].arch == nil {
                servers[i].agentVersion = sum.snapshot.host.agentVersion
                servers[i].arch = servers[i].arch ?? sum.snapshot.host.arch
                save()
            }
        } catch {
            var st = states[s.id] ?? ServerState()
            st.error = friendlyError(error)
            st.loading = false
            states[s.id] = st
        }
    }

    // MARK: push + peers

    /// APNs environment comes from the signing profile, not the build config:
    /// a Release build run from Xcode is still development-signed.
    var pushEnv: String { Self.apsEnvironment }

    static let apsEnvironment: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let r = text.range(of: #"<key>aps-environment</key>\s*<string>(\w+)</string>"#, options: .regularExpression)
        else { return "production" } // App Store / TestFlight builds carry no embedded profile
        return text[r].contains("development") ? "development" : "production"
    }()

    struct DeviceBody: Encodable { let token: String; let env: String; let name: String }
    struct APNsBody: Encodable { let keyId: String; let teamId: String; let bundleId: String; let keyP8: String }

    func registerDevice(on s: ServerRecord) async throws {
        guard let token = deviceToken else { return }
        try await api(for: s).send("POST", "/v1/devices", DeviceBody(token: token, env: pushEnv, name: UIDevice.current.name))
    }

    func deployAPNs(to s: ServerRecord) async throws {
        guard !s.isRelay, PushSettings.configured, let p8 = PushSettings.keyP8 else { return }
        try await api(for: s).send("PUT", "/v1/apns", APNsBody(keyId: PushSettings.keyID, teamId: PushSettings.teamID,
                                                               bundleId: PushSettings.bundleID, keyP8: p8))
    }

    /// Push key + this phone to every installed server; returns failures by name.
    func deployPushEverywhere() async -> [String: String] {
        var failures: [String: String] = [:]
        for s in sshServers where s.installed {
            do {
                try await deployAPNs(to: s)
                try await registerDevice(on: s)
            } catch {
                failures[s.name] = error.localizedDescription
            }
        }
        return failures
    }

    func didReceiveDeviceToken(_ token: String) {
        let changed = token != deviceToken
        deviceToken = token
        if changed {
            Task { for s in servers where s.installed { try? await registerDevice(on: s) } }
        }
    }

    /// Every server watches every other one (TCP to its SSH port).
    func syncPeers() async {
        let installed = sshServers.filter(\.installed)
        for s in installed {
            let peers = installed.filter { $0.id != s.id }.map { Peer(name: $0.name, host: $0.host, port: $0.port) }
            _ = try? await api(for: s).send("PUT", "/v1/peers", peers)
        }
    }

    func pushRulesEverywhere(_ rules: Rules) async -> [String: String] {
        var failures: [String: String] = [:]
        for s in sshServers where s.installed {
            do { try await api(for: s).send("PUT", "/v1/rules", rules) } catch { failures[s.name] = error.localizedDescription }
        }
        return failures
    }

    // MARK: team membership

    /// Joins a team from an invite link; replaces any earlier membership.
    func join(_ link: TeamJoin.Link) async throws {
        let acc = try await TeamJoin.redeem(link)
        member = acc
        servers.removeAll { $0.isRelay }
        save()
        await refreshMembership()
        await refreshAll()
    }

    func leaveTeam() {
        MemberAccount.clear()
        member = nil
        for s in servers where s.isRelay { states[s.id] = nil }
        servers.removeAll { $0.isRelay }
        save()
    }

    /// Member: the relay says which servers we may reach; mirror them locally.
    func refreshMembership() async {
        guard let m = member else { return }
        do {
            let me: MemberMe = try await RelayClient(baseURL: m.relayURL, bearer: MemberAccount.token).json("GET", "/m/v1/me")
            if me.role != m.role || me.name != m.name {
                var u = m
                u.role = me.role
                u.name = me.name
                u.save()
                member = u
            }
            memberActivated = me.activated
            var next = servers.filter { !$0.isRelay }
            for rs in me.servers {
                var rec = servers.first { $0.isRelay && $0.relayServerID == rs.id }
                    ?? ServerRecord(name: rs.name, host: URL(string: m.relayURL)?.host ?? "relay", port: 443, username: m.name, auth: .relay)
                rec.name = rs.name
                rec.relayServerID = rs.id
                rec.relayOnline = rs.online
                rec.installed = true
                next.append(rec)
            }
            if next != servers {
                servers = next
                save()
            }
        } catch let e as RelayError where e.status == 401 {
            // access was revoked
            leaveTeam()
        } catch {}
    }
}
