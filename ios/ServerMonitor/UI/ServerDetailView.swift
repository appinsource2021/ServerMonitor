import SwiftUI
import Charts

struct ServerDetailView: View {
    @Environment(ServerStore.self) private var store
    let serverID: UUID

    @State private var showHealth = false
    @State private var locked: Feature?
    private let plans = PlanStore.shared

    private var server: ServerRecord? { store.servers.first { $0.id == serverID } }
    private var state: ServerState { store.states[serverID] ?? ServerState() }

    var body: some View {
        Group {
            if let server {
                content(server)
            } else {
                Text("Server removed").foregroundStyle(Theme.text2)
            }
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: serverID) {
            // faster refresh while this screen is open
            while !Task.isCancelled {
                if let server { await store.refresh(server) }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder
    private func content(_ server: ServerRecord) -> some View {
        let snap = state.summary?.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(server.name).font(.system(size: 28, weight: .bold)).tracking(-0.5)
                        StatusChip(text: state.health.label, color: state.health.color)
                    }
                    Text(subtitle(server, snap)).font(.system(size: 13)).foregroundStyle(Theme.text2)
                }

                if let e = state.error {
                    ReconnectBanner(message: e) { await store.reconnect(server) }
                }
                ForEach(state.summary?.alerts ?? []) { a in
                    Banner(icon: "exclamationmark.triangle", title: a.title, text: a.message, color: a.health.color)
                }

                if let snap {
                    HStack(spacing: 10) {
                        RingGauge(label: "CPU", value: snap.cpuPercent, sub: "\(snap.host.cpus) cores")
                        RingGauge(label: "Memory", value: snap.memory.percent,
                                  sub: "\(Fmt.bytes(snap.memory.usedBytes)) / \(Fmt.bytes(snap.memory.totalBytes))")
                        if server.isRelay {
                            RingGauge(label: "Disk", value: snap.rootDisk?.percent ?? 0,
                                      sub: snap.rootDisk.map { "\(Fmt.bytes($0.usedBytes)) / \(Fmt.bytes($0.totalBytes))" } ?? "—")
                        } else if !plans.allows(.files) {
                            Button { locked = .files } label: {
                                RingGauge(label: "Disk", value: snap.rootDisk?.percent ?? 0,
                                          sub: snap.rootDisk.map { "\(Fmt.bytes($0.usedBytes)) / \(Fmt.bytes($0.totalBytes))" } ?? "—")
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: "lock.circle.fill").font(.system(size: 14))
                                            .foregroundStyle(Theme.text2).padding(8)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Disk analysis needs Pro")
                        } else {
                            NavigationLink { DiskUsageView(server: server) } label: {
                                RingGauge(label: "Disk", value: snap.rootDisk?.percent ?? 0,
                                          sub: snap.rootDisk.map { "\(Fmt.bytes($0.usedBytes)) / \(Fmt.bytes($0.totalBytes))" } ?? "—")
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: "chevron.right.circle.fill").font(.system(size: 14))
                                            .foregroundStyle(Theme.accent).padding(8)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows what uses the disk")
                        }
                    }
                    if !server.isRelay { toolsRow(server) }
                    cpuChart(snap)
                    if snap.disks.count > 1 { disks(snap) }

                    // Docker is a service of its own: its card shows the engine's state and
                    // load, and opens the container list. Everything else is "Other services".
                    NavigationLink { ContainersScreen(serverID: server.id) } label: {
                        DockerCard(snap: snap, history: state.summary?.history ?? [])
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the containers")
                    if store.seesLogs {
                        NavigationLink { ServicesScreen(serverID: server.id) } label: { ServicesCard(snap: snap) }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows the systemd services")
                    }
                } else if state.summary == nil && state.error == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .refreshable { await store.refresh(server) }
        .sheet(isPresented: $showHealth) { HealthCheckView(server: server) }
        .sheet(item: $locked) { PlanSheet(reason: $0) }
        .toolbar {
            // Separate, equatable view: data refreshes never redraw the open menu.
            if !server.isRelay {
                ToolbarItem(placement: .topBarTrailing) { ServerActionsMenu(server: server).equatable() }
            }
        }
    }

    private func toolsRow(_ server: ServerRecord) -> some View {
        HStack(spacing: 8) {
            Button { showHealth = true } label: { toolLabel("Health check", "stethoscope") }
            if plans.allows(.terminal) {
                NavigationLink { TerminalScreen(server: server, sshSession: store.session(for: server)) } label: {
                    toolLabel("Terminal", "terminal")
                }
            } else {
                Button { locked = .terminal } label: { toolLabel("Terminal", "lock") }
            }
        }
        .buttonStyle(.plain)
    }

    private func toolLabel(_ t: String, _ icon: String) -> some View {
        Label(t, systemImage: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    private func subtitle(_ s: ServerRecord, _ snap: Snapshot?) -> String {
        guard let snap else { return s.isRelay ? "via relay" : "\(s.host) · \(s.username)" }
        if s.isRelay {
            return [snap.host.os, "\(snap.host.cpus) vCPU", Fmt.bytes(snap.memory.totalBytes), "Up \(Fmt.uptime(snap.uptimeSeconds))"]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return [s.host, snap.host.os, "\(snap.host.cpus) vCPU", Fmt.bytes(snap.memory.totalBytes),
                "Up \(Fmt.uptime(snap.uptimeSeconds))"].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func cpuChart(_ snap: Snapshot) -> some View {
        let points = state.summary?.history ?? []
        return Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("CPU · last hour").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("load " + snap.load.map { String(format: "%.2f", $0) }.joined(separator: " / "))
                        .font(Theme.mono(12)).foregroundStyle(Theme.text2)
                }
                if points.count < 2 {
                    Text("Collecting data — the chart fills over the next minutes.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2).frame(height: 64)
                } else {
                    Chart {
                        RuleMark(y: .value("Alert", 90))
                            .foregroundStyle(Theme.crit.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        ForEach(points) { p in
                            LineMark(x: .value("Time", p.date), y: .value("CPU", p.cpu))
                                .foregroundStyle(Theme.accent)
                                .interpolationMethod(.monotone)
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis(.hidden)
                    .chartYAxis { AxisMarks(values: [0, 50, 100]) { _ in AxisValueLabel().font(Theme.mono(10)) } }
                    .frame(height: 64)
                    .accessibilityLabel("CPU usage over the last hour, now \(Int(snap.cpuPercent)) percent")
                }
            }
        }
    }

    private func disks(_ snap: Snapshot) -> some View {
        Card(padding: 14) {
            VStack(spacing: 12) {
                ForEach(snap.disks) { d in
                    MetricBar(label: d.mount + " · " + Fmt.bytes(d.freeBytes) + " free", value: d.percent)
                }
            }
        }
    }

}

/// The ··· menu. It reads only the server record, so the 5-second data refresh
/// does not invalidate it (that redraw made the open menu "breathe").
struct ServerActionsMenu: View, Equatable {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let server: ServerRecord

    @State private var showRemove = false
    @State private var updating: Installer?
    @State private var message: String?
    @State private var actionsOn: Bool?
    @State private var showManualUpdate = false

    static func == (a: Self, b: Self) -> Bool { a.server == b.server }

    var body: some View {
        Menu {
            Button {
                Task {
                    do {
                        try await store.deployAPNs(to: server)
                        try await store.registerDevice(on: server)
                        try await store.api(for: server).post("/v1/push/test")
                        message = "Test notification sent."
                    } catch { message = error.localizedDescription }
                }
            } label: { Label("Send test notification", systemImage: "bell.badge") }
            Button {
                Task {
                    struct C: Decodable { let allowActions: Bool }
                    do {
                        let cfg: C = try await store.api(for: server).get("/v1/config", timeout: .seconds(20))
                        actionsOn = cfg.allowActions
                    } catch { message = friendlyError(error) }
                }
            } label: { Label("Container & service actions…", systemImage: "switch.2") }
            if server.canUpdateFromApp {
                Button {
                    updating = store.startUpdate(server)
                } label: { Label("Update agent", systemImage: "arrow.down.circle") }
            }
            if server.externalAgent == true {
                Button { showManualUpdate = true } label: { Label("Update on the server…", systemImage: "doc.text") }
            }
            Divider()
            Button(role: .destructive) { showRemove = true } label: { Label("Remove server", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
        }
        .accessibilityLabel("Server actions")
        .confirmationDialog("Remove \(server.name)?", isPresented: $showRemove, titleVisibility: .visible) {
            if server.managesAgent {
                Button("Remove and uninstall agent", role: .destructive) {
                    Task { await store.remove(server, uninstall: true); dismiss() }
                }
            }
            Button("Remove from app only", role: .destructive) {
                Task { await store.remove(server, uninstall: false); dismiss() }
            }
        }
        .sheet(item: $updating) { inst in
            NavigationStack { InstallProgressView(installer: inst, title: "Updating \(server.name)") }
        }
        .sheet(isPresented: $showManualUpdate) {
            MonitoringSetupView(username: server.username, host: server.host, serverName: server.name, mode: .update, server: server)
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        }
        .alert(actionsOn == true ? "Container actions are ON" : "Container actions are OFF",
               isPresented: Binding(get: { actionsOn != nil }, set: { if !$0 { actionsOn = nil } })) {
            let on = actionsOn ?? false
            Button(on ? "Turn off" : "Turn on", role: on ? .destructive : nil) {
                Task {
                    struct S: Encodable { let allowActions: Bool }
                    do {
                        try await store.api(for: server).send("PUT", "/v1/settings", S(allowActions: !on))
                        message = on ? "Container actions turned off." : "Container actions turned on."
                    } catch { message = friendlyError(error) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(actionsOn == true
                 ? "Start, stop and restart work from the app on \(server.name)."
                 : "Start, stop and restart are blocked on \(server.name). Turn them on to control containers from the app.")
        }
    }
}

struct FilterField: View {
    @Binding var text: String
    let placeholder: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Theme.text2).font(.system(size: 14))
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search)
                .font(.system(size: 15))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3)
                }
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 12).frame(height: 42)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }
}

extension Installer: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

struct Banner: View {
    let icon: String
    let title: String
    let text: String
    let color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 17))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if !text.isEmpty { Text(text).font(.system(size: 13)).foregroundStyle(Color(hex: 0xC9CED6)) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.35)))
    }
}

struct ListCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Group { content }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct ContainerRow: View {
    let c: ContainerInfo
    var body: some View {
        HStack(spacing: 12) {
            StatusMark(health: c.health_)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                Text(c.stateLine).font(.system(size: 12))
                    .foregroundStyle(c.health_ == .critical ? Theme.crit : c.health_ == .warning ? Theme.warn : Theme.text2)
                    .lineLimit(1)
            }
            Spacer()
            if c.state == "running" {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f%% CPU", c.cpuPercent))
                    Text(Fmt.bytes(c.memBytes))
                }
                .font(Theme.mono(11)).foregroundStyle(Theme.text2)
            }
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .contentShape(Rectangle())
    }
}

struct ReconnectBanner: View {
    let message: String
    let reconnect: () async -> Void
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(Theme.crit).font(.system(size: 17))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection lost").font(.system(size: 13, weight: .semibold))
                    Text(message).font(.system(size: 13)).foregroundStyle(Color(hex: 0xC9CED6)).lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            Button {
                busy = true
                Task { await reconnect(); busy = false }
            } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small).tint(Theme.text) } else { Image(systemName: "arrow.clockwise") }
                    Text(busy ? "Reconnecting…" : "Reconnect")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Theme.crit.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.crit.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.crit.opacity(0.35)))
    }
}
