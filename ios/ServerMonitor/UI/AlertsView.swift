import SwiftUI

struct AlertsView: View {
    @Environment(ServerStore.self) private var store
    @State private var rules: Rules?
    @State private var saving = false
    @State private var message: String?
    @State private var editing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Alerts").font(.system(size: 34, weight: .bold)).tracking(-0.6).padding(.top, 8)

                    VStack(spacing: 8) {
                        SectionHeader(text: "Active · \(store.allActiveAlerts.count)")
                        if store.allActiveAlerts.isEmpty {
                            Card {
                                HStack(spacing: 10) {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.ok)
                                    Text("All quiet. No active alerts.").font(.system(size: 14)).foregroundStyle(Theme.text2)
                                }
                            }
                        } else {
                            ListCard {
                                ForEach(store.allActiveAlerts) { a in
                                    Button { store.openServerName = a.server } label: { AlertRow(alert: a) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if store.isAdmin {
                    VStack(spacing: 8) {
                        HStack {
                            SectionHeader(text: "Rules · all servers")
                            if rules != nil {
                                Button("Edit") { editing = true }.font(.system(size: 13, weight: .medium))
                            }
                        }
                        if let r = rules {
                            ListCard {
                                ruleRow("CPU", "> \(Int(r.cpu.percent))% · \(mins(r.cpu.forSeconds))", r.cpu.enabled) { rules?.cpu.enabled = $0 }
                                ruleRow("Memory", "> \(Int(r.memory.percent))%", r.memory.enabled) { rules?.memory.enabled = $0 }
                                ruleRow("Disk", "> \(Int(r.disk.percent))%", r.disk.enabled) { rules?.disk.enabled = $0 }
                                ruleRow("Container stopped", "", r.containerDown.enabled) { rules?.containerDown.enabled = $0 }
                                ruleRow("Container unhealthy", "", r.unhealthy.enabled) { rules?.unhealthy.enabled = $0 }
                                ruleRow("Restart loop", "\(r.restartLoop.count)× / \(mins(r.restartLoop.windowSeconds))", r.restartLoop.enabled) { rules?.restartLoop.enabled = $0 }
                                ruleRow("systemd unit failed", "", r.systemdFailed.enabled) { rules?.systemdFailed.enabled = $0 }
                                ruleRow("Server unreachable", mins(r.peerUnreachable.forSeconds), r.peerUnreachable.enabled) { rules?.peerUnreachable.enabled = $0 }
                            }
                            Text("Same alert is repeated at most every \(mins(r.cooldownSeconds)).")
                                .font(.system(size: 12)).foregroundStyle(Theme.text2)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                        } else if store.servers.contains(where: \.installed) {
                            Card { ProgressView().frame(maxWidth: .infinity) }
                        } else {
                            Card { Text("Add a server to configure rules.").font(.system(size: 14)).foregroundStyle(Theme.text2) }
                        }
                    }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .task { await loadRules() }
            .refreshable { await store.refreshAll(); await loadRules() }
            .sheet(isPresented: $editing) {
                if let r = rules {
                    RuleEditor(rules: r) { new in rules = new; Task { await save() } }
                }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            }
        }
    }

    private func mins(_ s: Int) -> String {
        s == 0 ? "immediately" : s < 120 ? "\(s) s" : "\(s / 60) min"
    }

    private func ruleRow(_ title: String, _ value: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { set($0); Task { await save() } })) {
            HStack {
                Text(title).font(.system(size: 14))
                Spacer()
                Text(value).font(Theme.mono(12)).foregroundStyle(Theme.text2)
            }
        }
        .tint(Theme.ok)
        .padding(.horizontal, 14).frame(minHeight: 50)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .disabled(saving)
    }

    private func loadRules() async {
        guard rules == nil, store.isAdmin, let s = store.sshServers.first(where: \.installed) else { return }
        do {
            let cfg: AgentConfig = try await store.api(for: s).get("/v1/config")
            rules = cfg.rules
        } catch {
            message = "Could not load rules from \(s.name): \(error.localizedDescription)"
        }
    }

    private func save() async {
        guard let r = rules else { return }
        saving = true
        let failures = await store.pushRulesEverywhere(r)
        saving = false
        if !failures.isEmpty {
            message = "Not saved on: " + failures.keys.sorted().joined(separator: ", ")
        }
    }
}

struct AlertRow: View {
    let alert: AgentAlert
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusMark(health: alert.health).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(alert.server).font(Theme.mono(12))
                    Spacer()
                    Text(Fmt.ago(alert.since)).font(.system(size: 12))
                }
                .foregroundStyle(Theme.text2)
                Text(alert.title).font(.system(size: 15, weight: .medium))
                if !alert.message.isEmpty {
                    Text(alert.message).font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .contentShape(Rectangle())
    }
}

struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rules: Rules
    let onSave: (Rules) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("CPU") {
                    Stepper("Above \(Int(rules.cpu.percent))%", value: $rules.cpu.percent, in: 50...100, step: 5)
                    Stepper("For \(rules.cpu.forSeconds / 60) min", value: $rules.cpu.forSeconds, in: 0...3600, step: 60)
                }
                Section("Memory") {
                    Stepper("Above \(Int(rules.memory.percent))%", value: $rules.memory.percent, in: 50...100, step: 5)
                    Stepper("For \(rules.memory.forSeconds / 60) min", value: $rules.memory.forSeconds, in: 0...3600, step: 60)
                }
                Section("Disk") {
                    Stepper("Above \(Int(rules.disk.percent))%", value: $rules.disk.percent, in: 50...100, step: 5)
                }
                Section("Containers") {
                    Stepper("Restart loop: \(rules.restartLoop.count) restarts", value: $rules.restartLoop.count, in: 2...20)
                    Stepper("…within \(rules.restartLoop.windowSeconds / 60) min", value: $rules.restartLoop.windowSeconds, in: 60...3600, step: 60)
                    Stepper("Unhealthy for \(rules.unhealthy.forSeconds) s", value: $rules.unhealthy.forSeconds, in: 0...600, step: 30)
                }
                Section("Servers") {
                    Stepper("Unreachable for \(rules.peerUnreachable.forSeconds / 60) min", value: $rules.peerUnreachable.forSeconds, in: 60...1800, step: 60)
                }
                Section("Notifications") {
                    Stepper("Repeat at most every \(rules.cooldownSeconds / 60) min", value: $rules.cooldownSeconds, in: 60...7200, step: 300)
                    Toggle("Notify when resolved", isOn: $rules.notifyResolved)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Alert rules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(rules); dismiss() } }
            }
        }
    }
}
