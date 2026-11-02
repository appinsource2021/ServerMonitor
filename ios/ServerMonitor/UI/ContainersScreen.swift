import SwiftUI
import Charts

extension Theme {
    /// Docker's own blue, used wherever the engine is meant.
    static let docker = Color(hex: 0x2496ED)
}

/// Multi-word filter: every word must appear (case-insensitive) in one of the fields.
enum TextFilter {
    static func matches(_ query: String, _ fields: [String?]) -> Bool {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        guard !words.isEmpty else { return true }
        let hay = fields.compactMap { $0?.lowercased() }.joined(separator: " ")
        return words.allSatisfy { hay.contains($0) }
    }
}

extension Snapshot {
    /// What the running containers use right now: CPU as a share of the whole host (0-100), memory in bytes.
    var containerLoad: (cpu: Double, mem: UInt64) {
        var cpu = 0.0
        var mem: UInt64 = 0
        for c in containers where c.state == "running" {
            cpu += c.cpuPercent
            mem += c.memBytes
        }
        if host.cpus > 0 { cpu /= Double(host.cpus) }
        return (min(cpu, 100), mem)
    }

    /// Container memory as a share of the host's memory.
    var containerMemPercent: Double {
        memory.totalBytes > 0 ? Double(containerLoad.mem) / Double(memory.totalBytes) * 100 : 0
    }

    /// The engine's systemd unit, when the services are visible.
    var engineService: ServiceInfo? { services.first { $0.name == "docker.service" } }

    /// Every service except the engine itself, which has its own card.
    var otherServices: [ServiceInfo] { services.filter { $0.name != "docker.service" } }

    /// Containers that count: `srvmon.ignore=true` keeps a container out of the status.
    var watchedContainers: [ContainerInfo] { containers.filter { $0.ignored != true } }

    /// Docker's own health: the engine first, then the containers.
    var dockerHealth: (health: Health, label: String) {
        if !dockerAvailable { return (.critical, "Not available") }
        if let e = engineService, e.active != "active" { return (.critical, e.active.capitalized) }
        let watched = watchedContainers
        if watched.contains(where: { $0.health_ == .critical }) { return (.critical, "Critical") }
        if watched.contains(where: { $0.health_ == .warning }) { return (.warning, "Warning") }
        return (.healthy, "Healthy")
    }
}

/// Rounded square with a symbol, the "app icon" of a service card.
struct ServiceIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 38, height: 38)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A number with a caption, for the stat rows on the cards.
struct StatCell: View {
    let title: String
    let value: Int
    var color: Color = Theme.text
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(color)
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The Docker section on the server screen: engine state, container counts, the load
/// the containers put on the host and how that load moved over the last hour.
struct DockerCard: View {
    let snap: Snapshot
    let history: [HistoryPoint]

    var body: some View {
        let status = snap.dockerHealth
        let running = snap.containers.filter { $0.state == "running" }.count
        let problems = snap.watchedContainers.filter { $0.health_ == .critical || $0.health_ == .warning }.count
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ServiceIcon(symbol: "shippingbox.fill", color: Theme.docker)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Docker").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(subtitle(running: running)).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    StatusChip(text: status.label, color: status.health.color)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
                }
                if snap.dockerAvailable {
                    HStack(spacing: 8) {
                        StatCell(title: "Running", value: running, color: running > 0 ? Theme.ok : Theme.text2)
                        StatCell(title: "Stopped", value: snap.containers.count - running, color: Theme.text2)
                        StatCell(title: "Problems", value: problems, color: problems > 0 ? Theme.crit : Theme.text2)
                        if let d = snap.docker { StatCell(title: "Images", value: d.images, color: Theme.text2) }
                    }
                    let load = snap.containerLoad
                    VStack(spacing: 10) {
                        MetricBar(label: "CPU · all containers", value: load.cpu)
                        MetricBar(label: "Memory · \(Fmt.bytes(load.mem)) of \(Fmt.bytes(snap.memory.totalBytes))", value: snap.containerMemPercent)
                    }
                    loadChart
                } else if let e = snap.dockerError, !e.isEmpty {
                    Text(e).font(.system(size: 12)).foregroundStyle(Theme.crit).lineLimit(3)
                }
            }
        }
    }

    private func subtitle(running: Int) -> String {
        guard snap.dockerAvailable else { return "The engine does not answer on its socket" }
        var parts: [String] = []
        if let d = snap.docker { parts.append("Engine \(d.version)") }
        if let e = snap.engineService, e.active != "active" { parts.append("docker.service \(e.active)") }
        parts.append("\(running) of \(snap.containers.count) running")
        return parts.joined(separator: " · ")
    }

    /// Container CPU against the host's over the last hour. Hidden until the agent records it
    /// (≥ 0.3.4) and while it is all zero (team members do not get this series).
    @ViewBuilder
    private var loadChart: some View {
        let pts = history.filter { $0.dockerCpu != nil }
        if pts.count >= 2, pts.contains(where: { ($0.dockerCpu ?? 0) > 0 }) {
            let peak = pts.map { max($0.cpu, $0.dockerCpu ?? 0) }.max() ?? 0
            let top = min(100, max(10, (peak / 10).rounded(.up) * 10))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("CPU · last hour").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    legend("Containers", Theme.docker)
                    legend("Host", Theme.text3)
                }
                Chart {
                    ForEach(pts) { p in
                        LineMark(x: .value("Time", p.date), y: .value("Host", p.cpu), series: .value("Series", "host"))
                            .foregroundStyle(Theme.text3.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .interpolationMethod(.monotone)
                        AreaMark(x: .value("Time", p.date), y: .value("Containers", p.dockerCpu ?? 0), series: .value("Series", "docker"))
                            .foregroundStyle(Theme.docker.opacity(0.18))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.date), y: .value("Containers", p.dockerCpu ?? 0), series: .value("Series", "docker"))
                            .foregroundStyle(Theme.docker)
                            .interpolationMethod(.monotone)
                    }
                }
                .chartYScale(domain: 0...top)
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel().font(Theme.mono(10)) } }
                .frame(height: 56)
                .accessibilityLabel("Container CPU over the last hour, now \(Int(snap.containerLoad.cpu)) percent of the host")
            }
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.text2)
        }
    }
}

/// The container list, one level below the server screen. Opens from the Docker card.
struct ContainersScreen: View {
    @Environment(ServerStore.self) private var store
    let serverID: UUID
    @State private var filter = ""

    private var server: ServerRecord? { store.servers.first { $0.id == serverID } }
    private var state: ServerState { store.states[serverID] ?? ServerState() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let server, let snap = state.summary?.snapshot {
                    header(server, snap)
                    if let e = state.error { ReconnectBanner(message: e) { await store.reconnect(server) } }
                    if let e = snap.engineService { engineRow(server, snap, e) }
                    FilterField(text: $filter, placeholder: "Filter containers — e.g. erp prod")
                    list(server, snap)
                } else if let server, let e = state.error {
                    ReconnectBanner(message: e) { await store.reconnect(server) }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .background(Theme.bg)
        .navigationTitle("Docker")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { if let server { await store.refresh(server) } }
        .scrollDismissesKeyboard(.immediately)
        .task(id: serverID) {
            // The server screen's loop stops while this one is on top; keep the data fresh here.
            while !Task.isCancelled {
                if let server { await store.refresh(server) }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func matching(_ snap: Snapshot) -> [ContainerInfo] {
        snap.containers.filter { TextFilter.matches(filter, [$0.name, $0.image, $0.composeProject, $0.composeService]) }
    }

    private func header(_ server: ServerRecord, _ snap: Snapshot) -> some View {
        let status = snap.dockerHealth
        let running = snap.containers.filter { $0.state == "running" }.count
        let shown = matching(snap).count
        var parts = [server.name]
        if let d = snap.docker {
            parts.append("Engine \(d.version)")
            parts.append("\(d.images) image\(d.images == 1 ? "" : "s")")
        }
        parts.append(shown == snap.containers.count ? "\(running) of \(snap.containers.count) running" : "\(shown) of \(snap.containers.count) shown")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ServiceIcon(symbol: "shippingbox.fill", color: Theme.docker)
                Text("Containers").font(.system(size: 28, weight: .bold)).tracking(-0.5)
                StatusChip(text: status.label, color: status.health.color)
            }
            Text(parts.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(Theme.text2)
        }
    }

    /// The engine's own unit, with its journal one tap away.
    private func engineRow(_ server: ServerRecord, _ snap: Snapshot, _ e: ServiceInfo) -> some View {
        var detail = ["docker.service"]
        if let d = snap.docker {
            if let s = d.storageDriver, !s.isEmpty { detail.append(s) }
            if let r = d.dataRoot, !r.isEmpty { detail.append(r) }
        }
        return ListCard {
            NavigationLink {
                LogsScreen(serverID: server.id, source: .service(e.name), title: "Docker engine")
            } label: {
                HStack(spacing: 12) {
                    StatusMark(health: e.health)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Docker engine").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                        Text(detail.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                    Spacer()
                    Text("\(e.active) · \(e.sub)").font(.system(size: 12))
                        .foregroundStyle(e.health == .critical ? Theme.crit : Theme.text2)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the engine's logs")
        }
    }

    @ViewBuilder
    private func list(_ server: ServerRecord, _ snap: Snapshot) -> some View {
        if !snap.dockerAvailable {
            Card { Text(snap.dockerError.map { "Docker not available: \($0)" } ?? "Docker not available on this server.")
                .font(.system(size: 13)).foregroundStyle(Theme.text2) }
        } else if snap.containers.isEmpty {
            Card { Text("No containers.").font(.system(size: 13)).foregroundStyle(Theme.text2) }
        } else if matching(snap).isEmpty {
            Card { Text("No container matches “\(filter)”.").font(.system(size: 13)).foregroundStyle(Theme.text2) }
        } else {
            ListCard {
                ForEach(matching(snap)) { c in
                    NavigationLink {
                        ContainerDetailView(serverID: server.id, containerName: c.name)
                    } label: {
                        ContainerRow(c: c)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
