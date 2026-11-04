import SwiftUI

/// "Other services" on the server screen: every systemd unit except the Docker engine,
/// which has its own card. Opens the service list.
struct ServicesCard: View {
    let snap: Snapshot

    var body: some View {
        let list = snap.otherServices
        let failed = list.filter { $0.active == "failed" }
        let active = list.filter { $0.active == "active" }.count
        let status: (health: Health, label: String) = {
            if !snap.systemdAvailable { return (.unknown, "No systemd") }
            if !failed.isEmpty { return (.critical, "\(failed.count) failed") }
            if list.contains(where: { $0.health == .warning }) { return (.warning, "Warning") }
            return (.healthy, "Healthy")
        }()
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ServiceIcon(symbol: "gearshape.2.fill", color: Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Other services").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(snap.systemdAvailable
                             ? "\(active) active · \(failed.count) failed · \(list.count) units"
                             : "systemd not available on this server")
                            .font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    StatusChip(text: status.label, color: status.health.color)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
                }
                if !failed.isEmpty {
                    let names = failed.prefix(4).map { $0.name.replacingOccurrences(of: ".service", with: "") }
                    Text("Failed: " + names.joined(separator: ", ") + (failed.count > 4 ? " +\(failed.count - 4) more" : ""))
                        .font(.system(size: 12)).foregroundStyle(Theme.crit).lineLimit(2)
                }
                let known = snap.knownServices.filter { $0.known.id != "docker" }
                if !known.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(known, id: \.unit.name) { k in
                                HStack(spacing: 5) {
                                    StatusMark(health: k.unit.health, size: 7)
                                    Text(k.known.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Theme.surface2, in: Capsule())
                                .overlay(Capsule().stroke(Theme.border))
                            }
                        }
                    }
                    .accessibilityLabel("Known services: " + known.map { "\($0.known.title) \($0.unit.active)" }.joined(separator: ", "))
                }
            }
        }
    }
}

/// The systemd service list, one level below the server screen. Opens from "Other services".
struct ServicesScreen: View {
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
                    FilterField(text: $filter, placeholder: "Filter services")
                    if filter.isEmpty { knownSection(server, snap) }
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
        .navigationTitle("Services")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { if let server { await store.refresh(server) } }
        .scrollDismissesKeyboard(.immediately)
        .task(id: serverID) {
            while !Task.isCancelled {
                if let server { await store.refresh(server) }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func matching(_ snap: Snapshot) -> [ServiceInfo] {
        snap.otherServices
            .filter { TextFilter.matches(filter, [$0.name, $0.description]) }
            .sorted { ($0.health.rank, $0.name) < ($1.health.rank, $1.name) }
    }

    private func header(_ server: ServerRecord, _ snap: Snapshot) -> some View {
        let all = snap.otherServices
        let failed = all.filter { $0.active == "failed" }.count
        let active = all.filter { $0.active == "active" }.count
        let shown = matching(snap).count
        let count = shown == all.count ? "\(all.count) units" : "\(shown) of \(all.count) shown"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ServiceIcon(symbol: "gearshape.2.fill", color: Theme.accent)
                Text("Services").font(.system(size: 28, weight: .bold)).tracking(-0.5)
                if failed > 0 { StatusChip(text: "\(failed) failed", color: Theme.crit) }
            }
            Text([server.name, "\(active) active", "\(failed) failed", count].joined(separator: " · "))
                .font(.system(size: 13)).foregroundStyle(Theme.text2)
        }
    }

    @ViewBuilder
    private func knownSection(_ server: ServerRecord, _ snap: Snapshot) -> some View {
        let known = snap.knownServices.filter { $0.known.id != "docker" }
        if !known.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(text: "Known services")
                ListCard {
                    ForEach(known, id: \.unit.name) { k in
                        NavigationLink {
                            ServiceDetailView(serverID: server.id, unitName: k.unit.name)
                        } label: {
                            HStack(spacing: 12) {
                                ServiceIcon(symbol: k.known.icon, color: k.known.color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(k.known.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                                    Text(k.unit.name.replacingOccurrences(of: ".service", with: "") + " · " + k.unit.sub)
                                        .font(.system(size: 12)).foregroundStyle(k.unit.health == .critical ? Theme.crit : Theme.text2)
                                }
                                Spacer()
                                StatusMark(health: k.unit.health)
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            SectionHeader(text: "All services")
        }
    }

    @ViewBuilder
    private func list(_ server: ServerRecord, _ snap: Snapshot) -> some View {
        if !snap.systemdAvailable {
            Card { Text("systemd not available.").font(.system(size: 13)).foregroundStyle(Theme.text2) }
        } else if matching(snap).isEmpty {
            Card { Text(filter.isEmpty ? "No services." : "No service matches “\(filter)”.").font(.system(size: 13)).foregroundStyle(Theme.text2) }
        } else {
            ListCard {
                ForEach(matching(snap)) { s in
                    NavigationLink {
                        ServiceDetailView(serverID: server.id, unitName: s.name)
                    } label: {
                        HStack(spacing: 12) {
                            StatusMark(health: s.health)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name.replacingOccurrences(of: ".service", with: "")).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                                Text("\(s.active) · \(s.sub)").font(.system(size: 12))
                                    .foregroundStyle(s.health == .critical ? Theme.crit : Theme.text2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
