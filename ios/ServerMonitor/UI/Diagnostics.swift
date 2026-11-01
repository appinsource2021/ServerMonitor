import SwiftUI

// MARK: - Manual health check

struct HealthCheckView: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let server: ServerRecord

    @State private var report: HealthReport?
    @State private var running = false
    @State private var error: String?
    @State private var sshMs: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary
                    if let error {
                        Banner(icon: "exclamationmark.triangle.fill", title: "Health check failed", text: error, color: Theme.crit)
                    }
                    if let r = report {
                        ListCard {
                            if let ms = sshMs {
                                CheckRow(item: HealthCheckItem(id: "conn", title: "Connection from this iPhone",
                                                               status: ms > 1500 ? "warn" : "ok",
                                                               detail: "\(ms) ms round trip", hint: nil))
                            }
                            ForEach(r.checks) { CheckRow(item: $0) }
                        }
                        .transition(.opacity)
                    } else if running {
                        ListCard {
                            ForEach(["CPU & load", "Memory & swap", "Disks & inodes", "Docker & containers", "System services", "OOM kills, clock, reboot"], id: \.self) { t in
                                HStack(spacing: 12) {
                                    ProgressView().controlSize(.small)
                                    Text(t).font(.system(size: 15)).foregroundStyle(Theme.text2)
                                    Spacer()
                                }
                                .padding(.horizontal, 14).frame(minHeight: 48)
                                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                            }
                        }
                    }
                }
                .padding(20)
                .animation(.easeOut(duration: 0.25), value: report?.time)
            }
            .background(Theme.bg)
            .navigationTitle("Health check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await run() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(running)
                        .accessibilityLabel("Run again")
                }
            }
            .task { await run() }
            .sensoryFeedback(trigger: report?.time) { _, _ in
                switch report?.overall ?? "" { case "ok": .success; case "warn": .warning; case "fail": .error; default: nil }
            }
        }
        .presentationBackground(Theme.bg)
    }

    private var summary: some View {
        let overall: Health = report.map { HealthCheckItem(id: "", title: "", status: $0.overall, detail: "", hint: nil).health } ?? .unknown
        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(overall.color.opacity(0.15)).frame(width: 56, height: 56)
                if running {
                    ProgressView().tint(Theme.accent)
                } else {
                    Image(systemName: overall == .healthy ? "checkmark" : overall == .warning ? "exclamationmark" : overall == .critical ? "xmark" : "stethoscope")
                        .font(.system(size: 24, weight: .bold)).foregroundStyle(overall.color)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name).font(.system(size: 20, weight: .bold))
                Text(running ? "Checking now…" : report.map { r in
                    let issues = r.checks.filter { $0.status == "fail" || $0.status == "warn" }.count
                    return (issues == 0 ? "All checks passed" : "\(issues) need attention") + " · \(r.durationMs) ms"
                } ?? "—")
                .font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
            Spacer()
        }
    }

    private func run() async {
        running = true
        error = nil
        defer { running = false }
        let t0 = Date()
        do {
            _ = try await store.api(for: server).raw("GET", "/v1/health")
            sshMs = Int(Date().timeIntervalSince(t0) * 1000)
            report = try await store.api(for: server).get("/v1/healthcheck")
        } catch let e as AgentAPI.HTTPError where e.status == 404 {
            error = "This server runs an older agent. Use ··· › Update agent, then try again."
        } catch {
            self.error = friendlyError(error)
        }
    }
}

struct CheckRow: View {
    let item: HealthCheckItem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(item.health.color).font(.system(size: 18)).frame(width: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 15, weight: .medium))
                Text(item.detail).font(.system(size: 13)).foregroundStyle(item.status == "fail" ? Theme.crit : Theme.text2)
                if let h = item.hint, item.status != "ok" {
                    Text(h).font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch item.status {
        case "ok": "checkmark.circle.fill"
        case "warn": "exclamationmark.circle.fill"
        case "fail": "xmark.octagon.fill"
        default: "minus.circle"
        }
    }
}

// MARK: - Disk analysis

struct SizeRow: View {
    let name: String
    let bytes: UInt64
    let total: UInt64
    var icon: String = "folder.fill"
    var chevron = false
    var separator = true

    var body: some View {
        let share = Double(bytes) / Double(total)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(Theme.accent.opacity(0.8)).font(.system(size: 14))
                Text(name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                Text(Fmt.bytes(bytes)).font(Theme.mono(13, .medium)).foregroundStyle(Theme.text)
                Text(String(format: "%.0f%%", share * 100)).font(Theme.mono(11)).foregroundStyle(Theme.text3).frame(width: 34, alignment: .trailing)
                if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border)
                    Capsule().fill(Theme.accent).frame(width: max(2, g.size.width * share))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(alignment: .bottom) { if separator { Rectangle().fill(Theme.border).frame(height: 1) } }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct DisclosureRow: View {
    let item: DockerDiskItem
    let total: UInt64
    let children: [DockerDiskItem]
    @State private var open = false

    var body: some View {
        VStack(spacing: 0) {
            Button { if !children.isEmpty { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } } label: {
                VStack(alignment: .leading, spacing: 0) {
                    SizeRow(name: item.name, bytes: item.bytes, total: total, icon: icon, chevron: false, separator: false)
                    HStack {
                        Text(item.detail ?? "").font(.system(size: 11)).foregroundStyle(Theme.text3)
                        Spacer()
                        if item.reclaimableBytes > 0 {
                            Text("\(Fmt.bytes(item.reclaimableBytes)) reclaimable").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.warn)
                        }
                        if !children.isEmpty {
                            Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3)
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 10).padding(.top, -4)
                }
            }
            .buttonStyle(.plain)
            if open {
                VStack(spacing: 0) {
                    ForEach(children) { c in
                        HStack {
                            Text(c.name).font(Theme.mono(12)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if c.reclaimableBytes > 0 {
                                Text("unused").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.warn)
                            }
                            Text(Fmt.bytes(c.bytes)).font(Theme.mono(12)).foregroundStyle(Theme.text)
                        }
                        .padding(.horizontal, 14).padding(.leading, 24).padding(.vertical, 7)
                    }
                }
                .padding(.bottom, 8)
                .background(Theme.surface2)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private var icon: String {
        switch item.name {
        case "Images": "square.stack.3d.up.fill"
        case "Build cache": "hammer.fill"
        case "Volumes": "externaldrive.fill"
        case "Container logs": "doc.text.fill"
        default: "shippingbox.fill"
        }
    }
}

// MARK: - Smart cleanup

struct CleanupView: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let server: ServerRecord
    var onDone: () -> Void = {}

    @State private var items: [CleanupItem]?
    @State private var selected = Set<String>()
    @State private var running = false
    @State private var confirm = false
    @State private var result: CleanupRunResponse?
    @State private var error: String?
    @State private var stopRequested = false

    private var safe: [CleanupItem] { (items ?? []).filter(\.isSafe) }
    private var review: [CleanupItem] { (items ?? []).filter { !$0.isSafe } }
    private var selectedBytes: UInt64 { (items ?? []).filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let result {
                        resultView(result)
                    } else if let items {
                        if items.isEmpty {
                            Card { Text("Nothing to clean — this server is tidy.").font(.system(size: 14)).foregroundStyle(Theme.text2) }
                        } else {
                            if !safe.isEmpty { section("Safe to clean", "Never touches running containers, volumes or app files.", safe) }
                            if !review.isEmpty { section("Review first", "Only remove these if you are sure they are not needed.", review) }
                        }
                    } else {
                        Card {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Looking for space to free…").font(.system(size: 14)).foregroundStyle(Theme.text2)
                            }
                        }
                    }
                    if let error { Banner(icon: "exclamationmark.triangle.fill", title: "Cleanup", text: error, color: Theme.crit) }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                if result == nil, let items, !items.isEmpty {
                    Group {
                        if running {
                            Button(role: .destructive) { Task { await stopCleanup() } } label: {
                                HStack(spacing: 8) {
                                    ProgressView().tint(Theme.crit)
                                    Text(stopRequested ? "Stopping after the current item…" : "Cleaning… · Stop")
                                }
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.crit)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Theme.crit.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.crit.opacity(0.4)))
                            }
                            .buttonStyle(.plain)
                            .disabled(stopRequested)
                        } else {
                            Button { confirm = true } label: { Text("Clean selected · \(Fmt.bytes(selectedBytes))") }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(selected.isEmpty)
                                .opacity(selected.isEmpty ? 0.5 : 1)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Theme.bg)
                }
            }
            .background(Theme.bg)
            .navigationTitle("Smart cleanup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(result == nil ? "Cancel" : "Done") { dismiss() } } }
            .interactiveDismissDisabled(running)
            .confirmationDialog("Free \(Fmt.bytes(selectedBytes)) on \(server.name)?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Clean \(selected.count) item\(selected.count == 1 ? "" : "s")", role: .destructive) { Task { await run() } }
            } message: {
                Text(review.contains { selected.contains($0.id) }
                     ? "Includes items marked “Review first”. Deleted files can't be restored."
                     : "Only caches and leftovers are removed. Deleted files can't be restored.")
            }
            .task { await load() }
            .sensoryFeedback(.success, trigger: result?.freedBytes)
        }
        .presentationBackground(Theme.bg)
    }

    private func section(_ title: String, _ sub: String, _ list: [CleanupItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: title)
            Text(sub).font(.system(size: 12)).foregroundStyle(Theme.text2).padding(.horizontal, 4)
            ListCard {
                ForEach(list) { it in
                    Button {
                        guard it.inUse == nil else { return }
                        if selected.contains(it.id) { selected.remove(it.id) } else { selected.insert(it.id) }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: it.inUse != nil ? "lock.fill" : selected.contains(it.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(it.inUse != nil ? Theme.text3 : selected.contains(it.id) ? Theme.accent : Theme.text3)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(it.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text(Fmt.bytes(it.bytes)).font(Theme.mono(13, .medium)).foregroundStyle(Theme.text)
                                }
                                Text(it.detail).font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                                if let p = it.paths, it.id.hasPrefix("dir:"), let first = p.first {
                                    Text(first).font(Theme.mono(10)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                                }
                                if let u = it.inUse {
                                    Text("Protected — \(u)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.warn)
                                }
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(running)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                    .accessibilityAddTraits(selected.contains(it.id) ? .isSelected : [])
                }
            }
        }
    }

    private func resultView(_ r: CleanupRunResponse) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(Theme.ok)
                Text("\(Fmt.bytes(r.freedBytes)) freed").font(.system(size: 28, weight: .bold))
                Text("on \(server.name)").font(.system(size: 14)).foregroundStyle(Theme.text2)
            }
            ListCard {
                ForEach(r.results) { x in
                    HStack {
                        Image(systemName: x.error == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(x.error == nil ? Theme.ok : Theme.warn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(items?.first { $0.id == x.id }?.title ?? x.id).font(.system(size: 14, weight: .medium))
                            if let e = x.error { Text(e).font(.system(size: 12)).foregroundStyle(Theme.warn) }
                        }
                        Spacer()
                        Text(Fmt.bytes(x.freedBytes)).font(Theme.mono(12)).foregroundStyle(Theme.text2)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
        }
    }

    private func load() async {
        do {
            let r: CleanupScanResponse = try await store.api(for: server).get("/v1/cleanup", timeout: .seconds(180))
            items = r.items
            selected = Set(r.items.filter { $0.isSafe && $0.inUse == nil }.map(\.id))
        } catch let e as AgentAPI.HTTPError where e.status == 404 || e.status == 405 {
            error = "This server runs an older agent. Use ··· › Update agent, then try again."
            items = []
        } catch {
            self.error = friendlyError(error)
            items = []
        }
    }

    private func stopCleanup() async {
        stopRequested = true
        do {
            _ = try await store.api(for: server).raw("DELETE", "/v1/cleanup", timeout: .seconds(20))
        } catch let e as AgentAPI.HTTPError where e.status == 404 || e.status == 405 {
            stopRequested = false
            error = "The agent on this server is older than 0.3.1 and cannot stop a cleanup. Update it with ··· › Update agent."
        } catch {
            stopRequested = false
            self.error = "Could not reach the server to stop: \(friendlyError(error))"
        }
    }

    private func run() async {
        running = true
        stopRequested = false
        defer { running = false }
        struct Body: Encodable { let ids: [String] }
        do {
            let data = try await store.api(for: server).send("POST", "/v1/cleanup", Body(ids: Array(selected)), timeout: .seconds(17 * 60))
            result = try JSON.decoder.decode(CleanupRunResponse.self, from: data)
            onDone()
            await store.refresh(server)
        } catch {
            self.error = friendlyError(error)
        }
    }
}
