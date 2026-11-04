import SwiftUI

struct ProcessInfoRow: Decodable, Identifiable, Hashable {
    let pid: Int
    let name: String
    let command: String
    let user: String
    let state: String
    let cpuPercent: Double
    let memBytes: UInt64
    let memPercent: Double
    let threads: Int
    let container: String?
    var id: Int { pid }

    var stateLabel: String {
        switch state {
        case "R": "Running"
        case "S": "Sleeping"
        case "D": "Waiting on disk"
        case "Z": "Zombie"
        case "T", "t": "Stopped"
        default: state
        }
    }
}

struct ProcessList: Decodable {
    let processes: [ProcessInfoRow]
    let total: Int
}

/// "What is using the CPU?": the busiest and biggest processes, measured by the agent over one
/// second. Opens from the server screen; read only. Needs agent 0.4.1.
struct ProcessesScreen: View {
    @Environment(ServerStore.self) private var store
    let serverID: UUID

    private enum Sort: Hashable { case cpu, memory }

    @State private var list: ProcessList?
    @State private var error: String?
    @State private var needsUpdate = false
    @State private var sort: Sort = .cpu
    @State private var filter = ""
    @State private var expanded: Int?

    private var server: ServerRecord? { store.servers.first { $0.id == serverID } }

    private var rows: [ProcessInfoRow] {
        (list?.processes ?? [])
            .filter { TextFilter.matches(filter, [$0.name, $0.command, $0.user, $0.container ?? ""]) }
            .sorted {
                switch sort {
                case .cpu: ($0.cpuPercent, $0.memBytes) > ($1.cpuPercent, $1.memBytes)
                case .memory: ($0.memBytes, $0.cpuPercent) > ($1.memBytes, $1.cpuPercent)
                }
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if needsUpdate {
                    Banner(icon: "arrow.down.circle", title: "Agent update needed",
                           text: "The process list needs agent 0.4.1 on this server. Update it from the server list.", color: Theme.warn)
                } else {
                    if let error { Banner(icon: "wifi.exclamationmark", title: "Could not refresh", text: error, color: Theme.crit) }
                    Segmented(options: [(Sort.cpu, "CPU"), (Sort.memory, "Memory")], selection: $sort)
                    FilterField(text: $filter, placeholder: "Filter processes")
                    content
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Theme.bg)
        .navigationTitle("Processes")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .scrollDismissesKeyboard(.immediately)
        .task(id: serverID) {
            while !Task.isCancelled && !needsUpdate {
                await load()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ServiceIcon(symbol: "list.bullet.rectangle", color: Theme.accent)
                Text("Processes").font(.system(size: 28, weight: .bold)).tracking(-0.5)
            }
            if let list {
                Text([server?.name ?? "", "\(list.total) running", "top \(list.processes.count) shown"].joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if list == nil {
            if error == nil { ProgressView().frame(maxWidth: .infinity).padding(40) }
        } else if rows.isEmpty {
            Card { Text("No process matches “\(filter)”.").font(.system(size: 13)).foregroundStyle(Theme.text2) }
        } else {
            ListCard {
                ForEach(rows) { p in row(p) }
            }
            Text("CPU is the share of the whole server over the last second.")
                .font(.system(size: 12)).foregroundStyle(Theme.text2).padding(.horizontal, 4)
        }
    }

    private func row(_ p: ProcessInfoRow) -> some View {
        Button {
            expanded = expanded == p.pid ? nil : p.pid
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(p.container.map { "\(p.user) · container \($0)" } ?? p.user)
                            .font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f%%", p.cpuPercent))
                            .font(Theme.mono(14, .medium)).monospacedDigit()
                            .foregroundStyle(p.cpuPercent >= 50 ? Theme.warn : Theme.text)
                        Text(Fmt.bytes(p.memBytes)).font(Theme.mono(11)).foregroundStyle(Theme.text2)
                    }
                }
                if expanded == p.pid {
                    Text(p.command.isEmpty ? "(no command line)" : p.command)
                        .font(Theme.mono(11)).foregroundStyle(Theme.text2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("PID \(p.pid) · \(p.stateLabel) · \(p.threads) threads · \(String(format: "%.1f", p.memPercent))% of memory")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard let server else { return }
        do {
            list = try await store.api(for: server).get("/v1/processes", timeout: .seconds(20))
            error = nil
        } catch let e as AgentAPI.HTTPError where e.status == 404 {
            needsUpdate = true
        } catch is CancellationError {
            return
        } catch {
            self.error = friendlyError(error)
        }
    }
}
