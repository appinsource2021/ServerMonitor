import SwiftUI

struct ServerListView: View {
    @Environment(ServerStore.self) private var store
    @State private var path: [ServerRecord] = []
    @State private var showAdd = false
    @State private var locked: Feature?
    private let plans = PlanStore.shared

    private func addServer() {
        if plans.canAddServer(current: store.servers.count) { showAdd = true } else { locked = .moreServers }
    }
    @State private var draft: ServerRecord?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    if store.servers.isEmpty {
                        empty
                    } else {
                        tiles
                        VStack(spacing: 12) {
                            ForEach(store.sortedServers) { s in
                                if s.installed {
                                    NavigationLink(value: s) {
                                        ServerCard(server: s, state: store.states[s.id] ?? ServerState())
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Button { draft = s } label: { DraftCard(server: s) }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button(role: .destructive) { Task { await store.remove(s, uninstall: false) } } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .refreshable { await store.refreshAll() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ServerRecord.self) { s in
                ServerDetailView(serverID: s.id)
            }
            .sheet(isPresented: $showAdd) {
                AddServerView()
            }
            .sheet(item: $locked) { PlanSheet(reason: $0) }
            .sheet(item: $draft) { d in
                AddServerView(draft: d)
            }
            .onChange(of: store.openServerName) { _, name in
                guard let name, let s = store.server(named: name) else { return }
                path = [s]
                store.openServerName = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Servers").font(.system(size: 34, weight: .bold)).tracking(-0.6)
                Text(updatedText).font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
            Spacer()
            if store.isAdmin {
            Button { addServer() } label: {
                Image(systemName: "plus").font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.bg)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent, in: Circle())
            }
            .accessibilityLabel("Add server")
            }
        }
        .padding(.top, 8)
    }

    private var updatedText: String {
        let last = store.states.values.compactMap(\.lastUpdate).max()
        guard let last else { return store.servers.isEmpty ? "No servers yet" : "Connecting…" }
        return "Updated \(Fmt.relative(last)) · SSH"
    }

    private var tiles: some View {
        let c = store.counts
        return HStack(spacing: 10) {
            CountTile(health: .healthy, count: c.healthy)
            CountTile(health: .warning, count: c.warning)
            CountTile(health: .critical, count: c.critical)
        }
    }

    @ViewBuilder
    private var empty: some View {
        if let m = store.member {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "hourglass").font(.system(size: 26)).foregroundStyle(Theme.accent)
                    Text("Welcome, \(m.name)").font(.system(size: 17, weight: .semibold))
                    Text(store.memberActivated
                         ? "No servers are shared with you yet. Ask the admin to give you access."
                         : "Your access is being activated. It appears here as soon as the admin's app is online.")
                        .font(.system(size: 14)).foregroundStyle(Theme.text2)
                }
            }
            .padding(.top, 20)
        } else {
            adminEmpty
        }
    }

    private var adminEmpty: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "server.rack").font(.system(size: 28)).foregroundStyle(Theme.accent)
                Text("Add your first server").font(.system(size: 17, weight: .semibold))
                Text("Enter its SSH login once. The app installs a small agent, then shows CPU, memory, disks, Docker containers and logs here.")
                    .font(.system(size: 14)).foregroundStyle(Theme.text2)
                Button("Add server") { addServer() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.top, 20)
    }
}

struct CountTile: View {
    let health: Health
    let count: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusMark(health: health, size: 8)
                Text(health.label).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Text("\(count)").font(.system(size: 26, weight: .semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
        .accessibilityElement(children: .combine)
    }
}

struct ServerCard: View {
    let server: ServerRecord
    let state: ServerState

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(server.host).font(Theme.mono(12)).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    if state.loading && state.summary == nil {
                        ProgressView().controlSize(.small)
                    }
                    StatusChip(text: state.health.label, color: state.health.color)
                }
                if let s = state.summary?.snapshot {
                    HStack(spacing: 12) {
                        MetricBar(label: "CPU", value: s.cpuPercent)
                        MetricBar(label: "RAM", value: s.memory.percent)
                        MetricBar(label: "Disk", value: s.maxDiskPercent)
                    }
                    Divider().overlay(Theme.border)
                    HStack(spacing: 14) {
                        if let cc = state.summary?.containerCount, s.dockerAvailable {
                            Label("\(cc.running)/\(cc.total) running", systemImage: "shippingbox")
                                .foregroundStyle(cc.problems > 0 ? Theme.crit : Theme.text2)
                        }
                        Text("Up \(Fmt.shortUptime(s.uptimeSeconds))")
                        Text("Load " + String(format: "%.2f", s.load.first ?? 0))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                } else if let e = state.error {
                    HStack(alignment: .center, spacing: 10) {
                        Text(e).font(.system(size: 12)).foregroundStyle(Theme.crit).lineLimit(2)
                        Spacer(minLength: 0)
                        ReconnectChip(server: server)
                    }
                } else if server.isRelay && server.relayOnline == false {
                    Text("Server not connected to the relay right now").font(.system(size: 12)).foregroundStyle(Theme.warn)
                } else if !server.installed {
                    Text("Agent not installed").font(.system(size: 12)).foregroundStyle(Theme.warn)
                }
                if server.installed, !server.isRelay, let v = server.agentVersion, BundledAgent.isOutdated(v) {
                    AgentUpdateChip(server: server, current: v)
                }
            }
        }
    }
}

/// Yellow strip on a server card when its agent is older than the one in the app.
/// Tapping anywhere on it starts the same update as ··· › Update agent.
struct AgentUpdateChip: View {
    @Environment(ServerStore.self) private var store
    let server: ServerRecord
    let current: String
    @State private var updating: Installer?
    @State private var showManual = false

    var body: some View {
        if server.canUpdateFromApp {
            Button {
                let inst = Installer(input: NewServerInput(host: server.host, username: server.username), store: store, existing: server)
                updating = inst
                Task { await inst.run() }
            } label: {
                strip(action: "Update now")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Agent update needed, server runs \(current). Update now")
            .sheet(item: $updating) { inst in
                NavigationStack { InstallProgressView(installer: inst, title: "Updating \(server.name)") }
            }
        } else {
            // Non-root login to an agent older than 0.3.6: it cannot replace itself yet.
            // The strip hands out the new binary and the script instead.
            Button { showManual = true } label: { strip(action: "Get files") }
                .buttonStyle(.plain)
                .accessibilityLabel("Agent update needed, server runs \(current). Get the files to update it on the server")
                .sheet(isPresented: $showManual) {
                    MonitoringSetupView(username: server.username, host: server.host, serverName: server.name, mode: .update, server: server)
                }
        }
    }

    private func strip(action: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent update needed").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warn)
                Text(action == "Get files"
                     ? "Server runs \(current) · app has \(BundledAgent.version) · once by hand on the server, then from here"
                     : "Server runs \(current) · app has \(BundledAgent.version)")
                    .font(.system(size: 11)).foregroundStyle(Theme.text2)
            }
            Spacer(minLength: 6)
            if let action {
                Text(action)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.bg)
                    .padding(.horizontal, 12).frame(minHeight: 32)
                    .background(Theme.warn, in: Capsule())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.warn.opacity(0.35)))
    }
}

struct ReconnectChip: View {
    @Environment(ServerStore.self) private var store
    let server: ServerRecord
    @State private var busy = false
    var body: some View {
        Button {
            busy = true
            Task { await store.reconnect(server); busy = false }
        } label: {
            HStack(spacing: 5) {
                if busy { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                Text("Reconnect")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10).frame(minHeight: 32)
            .background(Theme.crit.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

/// A server whose setup was started but not finished; everything typed is kept.
struct DraftCard: View {
    let server: ServerRecord
    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(Theme.warn).font(.system(size: 18))
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("\(server.username)@\(server.host) · setup not finished").font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                Spacer()
                Text("Continue")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.bg)
                    .padding(.horizontal, 12).frame(minHeight: 32)
                    .background(Theme.warn, in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the saved setup")
    }
}
