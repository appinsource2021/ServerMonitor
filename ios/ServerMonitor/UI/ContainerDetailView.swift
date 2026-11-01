import SwiftUI

/// Lifecycle of a start / stop / restart, shown on the buttons, the status chip and a banner.
enum ActionPhase: Equatable {
    case idle
    case sending(String, Date)    // command on its way to Docker
    case verifying(String, Date)  // command accepted, waiting to see the new state
    case done(String, TimeInterval)
    case failed(String, String)

    var action: String? {
        switch self {
        case .idle: nil
        case .sending(let a, _), .verifying(let a, _), .done(let a, _), .failed(let a, _): a
        }
    }
    var isWorking: Bool {
        switch self { case .sending, .verifying: true; default: false }
    }
    var startedAt: Date? {
        switch self { case .sending(_, let d), .verifying(_, let d): d; default: nil }
    }
}

extension String {
    /// "restart" → "Restarting", "stop" → "Stopping", "start" → "Starting"
    var progressive: String {
        switch self {
        case "stop": "Stopping"
        case "start": "Starting"
        case "restart": "Restarting"
        default: capitalized
        }
    }
    var pastTense: String {
        switch self {
        case "stop": "Stopped"
        case "start": "Started"
        case "restart": "Restarted"
        default: capitalized
        }
    }
}

struct ContainerDetailView: View {
    @Environment(ServerStore.self) private var store
    let serverID: UUID
    let containerName: String

    @State private var phase: ActionPhase = .idle
    @State private var confirm: String?
    @State private var logReload = 0
    @State private var enabling = false

    /// The agent refused because start/stop/restart is switched off in its config.
    private var actionsDisabled: Bool {
        if case .failed(_, let m) = phase { return m.contains("allow_actions") || m.contains("actions are turned off") }
        return false
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

    private var server: ServerRecord? { store.servers.first { $0.id == serverID } }
    private var container: ContainerInfo? {
        store.states[serverID]?.summary?.snapshot.containers.first { $0.name == containerName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let c = container {
                header(c)
                if store.canAct { actions(c) }
                if phase != .idle {
                    ActionBanner(phase: phase, container: containerName) { phase = .idle }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    if actionsDisabled, store.isAdmin, server?.isRelay == false {
                        Button { Task { await enableActions() } } label: {
                            HStack(spacing: 8) {
                                if enabling { ProgressView().tint(Theme.bg) } else { Image(systemName: "switch.2") }
                                Text("Turn on container actions for this server")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(enabling)
                    }
                }
                facts(c)
                    .opacity(phase.isWorking ? 0.55 : 1)
            } else {
                Text("Container not found (it may have been removed).").foregroundStyle(Theme.text2)
            }
            if let server {
                if store.seesLogs {
                    LogPanel(server: server, source: .container(containerName), reloadToken: logReload)
                } else {
                    Card {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.fill").foregroundStyle(Theme.text2)
                            Text("Logs are visible to admins only.").font(.system(size: 14)).foregroundStyle(Theme.text2)
                        }
                    }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: phase)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(phase.isWorking)
        .sensoryFeedback(trigger: phase) { _, new in
            switch new {
            case .sending: .impact(weight: .medium)
            case .done: .success
            case .failed: .error
            default: nil
            }
        }
        .confirmationDialog("\(confirm?.capitalized ?? "") \(containerName)?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            if let a = confirm {
                Button(a.capitalized, role: a == "stop" ? .destructive : nil) { Task { await run(a) } }
            }
        } message: {
            if confirm == "stop" { Text("The container stays stopped until you start it again.") }
            else if confirm == "restart" { Text("The service is unavailable for a few seconds.") }
        }
    }

    private func header(_ c: ContainerInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(c.name).font(.system(size: 26, weight: .bold)).tracking(-0.5).lineLimit(1).minimumScaleFactor(0.7)
                if phase.isWorking, let a = phase.action {
                    WorkingChip(text: a.progressive + "…")
                        .transition(.scale.combined(with: .opacity))
                } else {
                    StatusChip(text: chipText(c), color: c.health_.color)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            Text("\(c.image) · id \(c.id)").font(Theme.mono(12)).foregroundStyle(Theme.text2).lineLimit(1)
        }
    }

    private func chipText(_ c: ContainerInfo) -> String {
        switch c.state {
        case "exited": "Exited · \(c.exitCode)"
        case "running": c.health == "unhealthy" ? "Unhealthy" : "Running"
        default: c.state.capitalized
        }
    }

    private func actions(_ c: ContainerInfo) -> some View {
        let running = c.state == "running" || c.state == "restarting"
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
            // start is harmless: no confirmation
            if action == "start" { Task { await run(action) } } else { confirm = action }
        } label: {
            HStack(spacing: 8) {
                if active {
                    ProgressView().controlSize(.small).tint(fg)
                    Text(action.progressive + "…")
                } else {
                    Image(systemName: icon)
                    Text(action.capitalized)
                }
            }
            .font(.system(size: 15, weight: primary ? .semibold : .medium))
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(primary ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(primary ? .clear : Theme.border))
            .overlay {
                if active { ShimmerSweep().clipShape(RoundedRectangle(cornerRadius: 12)) }
            }
            .opacity(dimmed ? 0.35 : 1)
            .scaleEffect(active ? 0.98 : 1)
        }
        .buttonStyle(.plain)
        .disabled(phase.isWorking)
        .accessibilityLabel(active ? action.progressive : action.capitalized)
    }

    private func facts(_ c: ContainerInfo) -> some View {
        let items: [(String, String, Color)] = [
            ("Status", c.stateLine, c.health_ == .critical ? Theme.crit : Theme.text),
            ("Restarts", "\(c.restartCount)", c.restartCount > 0 ? Theme.warn : Theme.text),
            ("Memory", c.memLimitBytes > 0 ? "\(Fmt.bytes(c.memBytes)) / \(Fmt.bytes(c.memLimitBytes))" : Fmt.bytes(c.memBytes), Theme.text),
            ("Restart policy", c.restartPolicy.isEmpty ? "no" : c.restartPolicy, Theme.text),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).font(.system(size: 11)).foregroundStyle(Theme.text2)
                    Text(item.1).font(.system(size: 14, weight: .medium)).foregroundStyle(item.2).lineLimit(1).minimumScaleFactor(0.8)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)
            }
        }
        .background(Theme.border)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
    }

    /// Sends the action, then confirms the container really reached the new state.
    private func run(_ action: String) async {
        guard let server, !phase.isWorking else { return }
        let before = container
        let t0 = Date()
        phase = .sending(action, t0)
        do {
            try await store.api(for: server).post("/v1/containers/\(containerName)/\(action)")
            phase = .verifying(action, t0)
            // Agent ≥0.1.1 refreshes right away; older agents need a few polls.
            var reached = false
            for _ in 0..<20 {
                await store.refresh(server)
                if let now = container, Self.reached(action, before: before, now: now) { reached = true; break }
                try? await Task.sleep(for: .seconds(1))
            }
            if reached {
                phase = .done(action, Date().timeIntervalSince(t0))
                logReload += 1
                try? await Task.sleep(for: .seconds(2.5))
                if case .done = phase { phase = .idle }
            } else {
                phase = .failed(action, "Docker accepted the command, but the container has not reached the expected state yet. Pull to refresh in a moment.")
            }
        } catch let e as AgentAPI.HTTPError where e.message.contains("allow_actions") {
            phase = .failed(action, store.isAdmin
                ? "Container actions are turned off for this server. Turn them on below, or later under ··· › Container actions."
                : "Container actions are turned off for this server. Ask the admin to turn them on.")
        } catch {
            phase = .failed(action, error.localizedDescription)
        }
    }

    static func reached(_ action: String, before: ContainerInfo?, now: ContainerInfo) -> Bool {
        switch action {
        case "stop": return now.state == "exited" || now.state == "dead"
        case "start": return now.state == "running"
        case "restart":
            guard now.state == "running" else { return false }
            guard let old = before?.startedAt, let new = now.startedAt else { return true }
            return old != new
        default: return true
        }
    }
}

/// Pulsing amber chip shown in place of the status while an action runs.
struct WorkingChip: View {
    let text: String
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.warn).frame(width: 7, height: 7)
                .scaleEffect(pulse ? 1.35 : 0.8)
                .opacity(pulse ? 1 : 0.5)
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.warn)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.warn.opacity(0.14), in: Capsule())
        .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

/// A soft light band moving across the active button.
struct ShimmerSweep: View {
    @State private var x: CGFloat = -1
    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.45)
                .offset(x: x * g.size.width)
                .onAppear {
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { x = 1.2 }
                }
        }
        .allowsHitTesting(false)
    }
}

/// Step-by-step progress for the running action, then its result.
struct ActionBanner: View {
    let phase: ActionPhase
    let container: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let start = phase.startedAt {
                    TimelineView(.periodic(from: start, by: 0.1)) { ctx in
                        Text(String(format: "%.1f s", ctx.date.timeIntervalSince(start)))
                            .font(Theme.mono(12, .medium)).foregroundStyle(Theme.text2)
                            .monospacedDigit()
                    }
                } else if case .failed = phase {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.text2)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Dismiss")
                }
            }
            if phase.isWorking {
                steps
                IndeterminateBar(color: Theme.accent)
            }
        }
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch phase {
        case .done: Theme.ok
        case .failed: Theme.crit
        default: Theme.accent
        }
    }

    @ViewBuilder private var icon: some View {
        switch phase {
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.ok)
                .transition(.scale)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 20)).foregroundStyle(Theme.crit)
        default: ProgressView().tint(Theme.accent)
        }
    }

    private var title: String {
        switch phase {
        case .idle: ""
        case .sending(let a, _), .verifying(let a, _): "\(a.progressive) \(container)…"
        case .done(let a, let t): "\(a.pastTense) in \(String(format: "%.1f", t)) s"
        case .failed(let a, _): "\(a.capitalized) failed"
        }
    }

    private var subtitle: String {
        switch phase {
        case .idle: ""
        case .sending(let a, _):
            a == "start" ? "Sending command to Docker" : "Docker is stopping the container (up to 10 s)"
        case .verifying: "Checking the new container state"
        case .done(let a, _): a == "stop" ? "Container is stopped." : "Container is up and running."
        case .failed(_, let m): m
        }
    }

    private var steps: some View {
        let verifying: Bool = { if case .verifying = phase { true } else { false } }()
        return HStack(spacing: 6) {
            StepDot(label: "Command", state: verifying ? .done : .active)
            Rectangle().fill(verifying ? Theme.ok : Theme.border).frame(height: 2).frame(maxWidth: 28)
            StepDot(label: "Docker", state: verifying ? .done : .pending)
            Rectangle().fill(verifying ? Theme.accent : Theme.border).frame(height: 2).frame(maxWidth: 28)
            StepDot(label: "Verify", state: verifying ? .active : .pending)
        }
    }
}

struct StepDot: View {
    enum S { case pending, active, done }
    let label: String
    let state: S
    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().fill(state == .done ? Theme.ok : state == .active ? Theme.accent : Theme.border).frame(width: 14, height: 14)
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.bg)
                }
            }
            Text(label).font(.system(size: 11, weight: state == .active ? .semibold : .regular))
                .foregroundStyle(state == .pending ? Theme.text3 : Theme.text)
        }
    }
}

struct IndeterminateBar: View {
    let color: Color
    @State private var x: CGFloat = -0.4
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule().fill(color)
                    .frame(width: g.size.width * 0.35)
                    .offset(x: x * g.size.width)
            }
            .clipShape(Capsule())
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) { x = 1.05 }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

enum LogSource: Hashable {
    case container(String)
    case service(String)

    func path(tail: Int) -> String {
        switch self {
        case .container(let n): "/v1/containers/\(n)/logs?tail=\(tail)"
        case .service(let n): "/v1/services/\(n)/logs?tail=\(tail)"
        }
    }
}

struct LogsScreen: View {
    @Environment(ServerStore.self) private var store
    let serverID: UUID
    let source: LogSource
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 22, weight: .bold)).lineLimit(1)
            if let s = store.servers.first(where: { $0.id == serverID }) {
                LogPanel(server: s, source: source)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LogPanel: View {
    @Environment(ServerStore.self) private var store
    let server: ServerRecord
    let source: LogSource
    var reloadToken = 0

    @State private var lines: [LogLine] = []
    @State private var errorsOnly = false
    @State private var follow = true
    @State private var search = ""
    @State private var showSearch = false
    @State private var error: String?
    @State private var loaded = false

    private var shown: [LogLine] {
        lines.filter { l in
            (!errorsOnly || l.level == .error) && (search.isEmpty || l.text.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Logs").font(.system(size: 14, weight: .semibold))
                Spacer()
                pill("All", on: !errorsOnly) { errorsOnly = false }
                pill("Errors", on: errorsOnly) { errorsOnly = true }
                Button { follow.toggle() } label: {
                    HStack(spacing: 5) {
                        Circle().fill(follow ? Theme.accent : Theme.text3).frame(width: 6, height: 6)
                        Text("Follow")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(follow ? Theme.accent : Theme.text2)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(follow ? Theme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityAddTraits(follow ? .isSelected : [])
                Button { showSearch.toggle(); if !showSearch { search = "" } } label: {
                    Image(systemName: "magnifyingglass").frame(width: 30, height: 30)
                }
                .foregroundStyle(Theme.text2)
                .accessibilityLabel("Search logs")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.surface)

            if showSearch {
                TextField("Search", text: $search)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(Theme.mono(13))
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(Theme.surface2)
            }
            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if let error {
                            Text(error).font(Theme.mono(11)).foregroundStyle(Theme.crit)
                        } else if !loaded {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        } else if shown.isEmpty {
                            Text(lines.isEmpty ? "No log output." : "No matching lines.").font(Theme.mono(11)).foregroundStyle(Theme.text3)
                        }
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, l in
                            LogRow(line: l)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                    .textSelection(.enabled)
                }
                .onChange(of: lines.count) { _, _ in
                    if follow { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onChange(of: loaded) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .background(Theme.logBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border))
        .onChange(of: reloadToken) { _, _ in Task { await load() } }
        .task(id: source) {
            while !Task.isCancelled {
                if follow || !loaded { await load() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func pill(_ t: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Theme.text : Theme.text2)
                .padding(.horizontal, 10).frame(height: 30)
                .background(on ? Theme.border : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func load() async {
        do {
            let r: LogsResponse = try await store.api(for: server).get(source.path(tail: 400))
            if r.lines != lines { lines = r.lines }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

struct LogRow: View {
    let line: LogLine
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let t = line.time {
                Text(Fmt.logTime(t)).foregroundStyle(Theme.text3)
            }
            Text(line.text)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.mono(11))
    }

    private var color: Color {
        switch line.level {
        case .error: Color(hex: 0xF2B8B8)
        case .warn: Color(hex: 0xE8D3A8)
        case .info: Color(hex: 0xC9CED6)
        }
    }
}
