import SwiftUI

/// One systemd service: state, Start / Stop / Restart (agent ≥ 0.4.0, same switch as
/// container actions) and its journal. Opens from the Services screen.
struct ServiceDetailView: View {
    @Environment(ServerStore.self) private var store
    let serverID: UUID
    let unitName: String

    @State private var phase: ActionPhase = .idle
    @State private var confirm: String?
    @State private var logReload = 0
    @State private var enabling = false
    @State private var locked: Feature?
    private let plans = PlanStore.shared

    private var server: ServerRecord? { store.servers.first { $0.id == serverID } }
    private var unit: ServiceInfo? {
        store.states[serverID]?.summary?.snapshot.services.first { $0.name == unitName }
    }
    private var known: KnownService? { KnownService.match(unitName) }
    private var shortName: String { unitName.replacingOccurrences(of: ".service", with: "") }

    private var actionsDisabled: Bool {
        if case .failed(_, let m) = phase { return m.contains("allow_actions") }
        return false
    }
    private var needsNewerAgent: Bool {
        if case .failed(_, let m) = phase { return m.contains("agent 0.4.0") }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let u = unit {
                    header(u)
                    if let server, !server.isRelay, store.canAct { actions(u) }
                    if phase != .idle {
                        ActionBanner(phase: phase, container: shortName, subject: "Service", engine: "systemd") { phase = .idle }
                        if actionsDisabled, store.isAdmin {
                            Button { Task { await enableActions() } } label: {
                                HStack(spacing: 8) {
                                    if enabling { ProgressView().tint(Theme.bg) } else { Image(systemName: "switch.2") }
                                    Text("Turn on actions for this server")
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(enabling)
                        }
                    }
                    facts(u).opacity(phase.isWorking ? 0.55 : 1)
                } else {
                    Text("Service not found (it may have been removed).").foregroundStyle(Theme.text2)
                }
                if let server, store.seesLogs {
                    LogPanel(server: server, source: .service(unitName), reloadToken: logReload)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Theme.bg)
        .navigationTitle(known?.title ?? shortName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { if let server { await store.refresh(server) } }
        .sheet(item: $locked) { PlanSheet(reason: $0) }
        .confirmationDialog("\(confirm?.capitalized ?? "") \(shortName)?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            Button(confirm?.capitalized ?? "", role: confirm == "stop" ? .destructive : nil) {
                if let a = confirm { Task { await run(a) } }
                confirm = nil
            }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: {
            Text(confirmMessage)
        }
        .task(id: serverID) {
            while !Task.isCancelled {
                if let server { await store.refresh(server) }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var confirmMessage: String {
        if unitName.hasPrefix("docker") { return "Every container on this server goes down with the Docker engine." }
        return confirm == "stop" ? "The service stops until someone starts it again." : "The service is briefly unavailable while it restarts."
    }

    private func header(_ u: ServiceInfo) -> some View {
        HStack(spacing: 12) {
            ServiceIcon(symbol: known?.icon ?? "gearshape.2.fill", color: known?.color ?? Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(known?.title ?? shortName).font(.system(size: 22, weight: .bold)).tracking(-0.3)
                Text(u.description.isEmpty ? unitName : u.description).font(.system(size: 13)).foregroundStyle(Theme.text2).lineLimit(2)
            }
            Spacer(minLength: 8)
            StatusChip(text: stateLabel(u), color: u.health.color)
        }
    }

    private func stateLabel(_ u: ServiceInfo) -> String {
        switch (u.active, u.sub) {
        case ("active", "running"): "Running"
        case ("active", "exited"): "Done"
        case ("failed", _): "Failed"
        case ("inactive", _): "Stopped"
        case ("activating", _): "Starting"
        case ("deactivating", _): "Stopping"
        default: u.active.capitalized
        }
    }

    private func actions(_ u: ServiceInfo) -> some View {
        let running = u.active == "active" || u.active == "activating"
        return HStack(spacing: 8) {
            if running {
                actionButton("restart", "arrow.clockwise", primary: true)
                actionButton("stop", "stop.fill", primary: false)
            } else {
                actionButton("start", "play.fill", primary: true)
                actionButton("restart", "arrow.clockwise", primary: false)
            }
        }
    }

    private func actionButton(_ action: String, _ icon: String, primary: Bool) -> some View {
        let active = phase.isWorking && phase.action == action
        let dimmed = phase.isWorking && !active
        let fg = primary ? Theme.bg : Theme.text
        return Button {
            guard plans.allows(.serviceActions) else { locked = .serviceActions; return }
            if action == "start" { Task { await run(action) } } else { confirm = action }
        } label: {
            HStack(spacing: 8) {
                if active {
                    ProgressView().controlSize(.small).tint(fg)
                    Text(action.progressive + "…")
                } else {
                    Image(systemName: plans.allows(.serviceActions) ? icon : "lock")
                    Text(action.capitalized)
                }
            }
            .font(.system(size: 15, weight: primary ? .semibold : .medium))
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(primary ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(primary ? .clear : Theme.border))
            .opacity(dimmed ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(phase.isWorking)
        .accessibilityLabel("\(action.capitalized) \(shortName)")
    }

    private func facts(_ u: ServiceInfo) -> some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                factRow("Unit", unitName)
                factRow("State", "\(u.active) · \(u.sub)")
                factRow("Loaded", u.load)
                if let known { factRow("Recognised as", known.title) }
            }
        }
    }

    private func factRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 14)).foregroundStyle(Theme.text2)
            Spacer()
            Text(v).font(Theme.mono(12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 14).frame(minHeight: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private static func reached(_ action: String, now: ServiceInfo) -> Bool {
        switch action {
        case "stop": now.active == "inactive" || now.active == "failed"
        default: now.active == "active"
        }
    }

    private func run(_ action: String) async {
        guard let server, !phase.isWorking else { return }
        let t0 = Date()
        phase = .sending(action, t0)
        do {
            try await store.api(for: server).post("/v1/services/\(unitName)/\(action)")
            phase = .verifying(action, t0)
            var reached = false
            for _ in 0..<20 {
                await store.refresh(server)
                if let now = unit, Self.reached(action, now: now) { reached = true; break }
                try? await Task.sleep(for: .seconds(1))
            }
            if reached {
                phase = .done(action, Date().timeIntervalSince(t0))
                logReload += 1
                try? await Task.sleep(for: .seconds(2.5))
                if case .done = phase { phase = .idle }
            } else {
                phase = .failed(action, "systemd accepted the command, but the service has not reached the expected state yet. Pull to refresh in a moment.")
            }
        } catch let e as AgentAPI.HTTPError where e.message.contains("allow_actions") {
            phase = .failed(action, store.isAdmin
                ? "Actions are turned off for this server. Turn them on below, or later under ··· › Container & service actions."
                : "Actions are turned off for this server (allow_actions). Ask the admin to turn them on.")
        } catch let e as AgentAPI.HTTPError where e.status == 404 {
            phase = .failed(action, "Service actions need agent 0.4.0 on this server. Update it from the server list.")
        } catch {
            phase = .failed(action, friendlyError(error))
        }
    }

    private func enableActions() async {
        guard let server else { return }
        enabling = true
        defer { enabling = false }
        struct S: Encodable { let allowActions: Bool }
        do {
            try await store.api(for: server).send("PUT", "/v1/settings", S(allowActions: true))
            phase = .idle
        } catch {
            phase = .failed("enable", friendlyError(error))
        }
    }
}
