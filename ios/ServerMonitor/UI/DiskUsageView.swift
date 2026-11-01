import SwiftUI

/// Disk drill-down: folder sizes (du scan), Docker's share, and the files in the
/// folder. Folders and files can be deleted with a swipe; files open in `FileEditorView`.
struct DiskUsageView: View {
    @Environment(ServerStore.self) private var store
    let server: ServerRecord
    var path: String = "/"

    @State private var scan: DiskScan?
    @State private var docker: DockerDisk?
    @State private var listing: FSListing?
    @State private var listingNote: String?       // why the file list is missing
    @State private var error: String?
    @State private var polling = false
    @State private var showCleanup = false
    @State private var stopping = false
    @State private var stoppedLocally = false     // the user pressed Stop; the screen no longer waits
    @State private var stopNote: String?          // what happened on the server side
    @State private var pollFailures = 0
    @State private var pollError: String?
    @State private var localStart: Date?
    @State private var pendingDelete: DeleteTarget?
    @State private var deleting = false
    @State private var removed: Set<String> = []  // deleted in this screen; hidden until the next scan
    @State private var notice: String?

    private var disk: DiskInfo? {
        let snap = store.states[server.id]?.summary?.snapshot
        return snap?.disks.first { path == $0.mount || path.hasPrefix($0.mount == "/" ? "/" : $0.mount + "/") } ?? snap?.rootDisk
    }

    private var inUseByPath: [String: String] {
        var m: [String: String] = [:]
        for e in listing?.entries ?? [] { if let u = e.inUse { m[e.path] = u } }
        return m
    }

    var body: some View {
        List {
            Section { header }.plainRow()
            if let error {
                Section { Banner(icon: "exclamationmark.triangle.fill", title: "Something went wrong", text: error, color: Theme.crit) }.plainRow()
            }
            if let notice {
                Section { Banner(icon: "checkmark.circle.fill", title: notice, text: "Pull down to measure the folders again.", color: Theme.ok) }.plainRow()
            }
            if path == "/" {
                Section {
                    Button { showCleanup = true } label: { Label("Smart cleanup", systemImage: "sparkles") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .plainRow()
                dockerSection
            }
            foldersSection
            filesSection
            let big = (scan?.largestFiles ?? []).filter { !removed.contains($0.path) }
            if !big.isEmpty { largestSection(big) }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(14)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(path == "/" ? "Disk" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(scan?.status == "running")
                    .accessibilityLabel("Scan again")
            }
        }
        .task { await load(force: false) }
        .refreshable { await load(force: true) }
        .sheet(isPresented: $showCleanup) {
            CleanupView(server: server) { Task { docker = nil; await load(force: true) } }
        }
        .sheet(item: $pendingDelete) { t in
            DeleteSheet(target: t, busy: deleting) { Task { await performDelete(t) } }
        }
    }

    // MARK: sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(path).font(Theme.mono(13)).foregroundStyle(Theme.text2).textSelection(.enabled)
            if let d = disk {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.bytes(d.usedBytes)).font(.system(size: 28, weight: .bold))
                    Text("used of \(Fmt.bytes(d.totalBytes)) · \(Fmt.bytes(d.freeBytes)) free").font(.system(size: 13)).foregroundStyle(Theme.text2)
                }
                MetricBar(label: "Disk \(d.mount)", value: d.percent)
            }
            if let l = listing, let u = l.inUse {
                Label("This folder is in use: \(u)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.crit)
            }
        }
        // the inset-grouped cell clips its rounded corners: keep the first and last
        // lines well away from the top and bottom edges
        .padding(.vertical, 14)
    }

    private func sectionHeader(_ text: String, trailing: String? = nil) -> some View {
        HStack {
            SectionHeader(text: text)
            if let trailing { Text(trailing).font(Theme.mono(12)).foregroundStyle(Theme.text2) }
        }
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 6, trailing: 0))
    }

    // Docker usually explains "where did the space go" on a single-app server
    @ViewBuilder private var dockerSection: some View {
        Section {
            if let d = docker {
                if !d.available {
                    note(d.error.map { "Docker not available: \($0)" } ?? "Docker not available")
                } else {
                    ForEach([d.images, d.buildCache, d.volumes, d.logs, d.containers]) { item in
                        DisclosureRow(item: item, total: max(d.totalBytes, 1), children: children(for: item, in: d)).cardRow()
                    }
                }
            } else {
                HStack(spacing: 10) { ProgressView(); Text("Asking Docker…").font(.system(size: 14)).foregroundStyle(Theme.text2) }
                    .padding(14).cardRow()
            }
        } header: {
            sectionHeader("Docker", trailing: docker.flatMap { $0.available ? Fmt.bytes($0.totalBytes) : nil })
        }
        if let d = docker, d.available, d.reclaimableBytes > 0 {
            Section {
                Banner(icon: "sparkles", title: "\(Fmt.bytes(d.reclaimableBytes)) can be freed",
                       text: "Unused images, stopped containers, unused volumes and build cache. Smart cleanup above removes them safely.",
                       color: Theme.accent)
            }
            .plainRow()
        }
    }

    private func children(for item: DockerDiskItem, in d: DockerDisk) -> [DockerDiskItem] {
        switch item.name {
        case d.images.name: d.topImages
        case d.volumes.name: d.topVolumes
        case d.logs.name: d.topLogs
        default: []
        }
    }

    /// Folders the du scan did not measure (other filesystems, or the scan is still running).
    private var unmeasuredDirs: [FSEntry] {
        guard let l = listing else { return [] }
        let measured: Set<String> = scan?.status == "done" ? Set(scan?.entries.map(\.path) ?? []) : []
        return l.entries.filter { $0.isDir && !measured.contains($0.path) && !removed.contains($0.path) }
    }

    @ViewBuilder private var foldersSection: some View {
        let done = scan?.status == "done"
        let entries = (scan?.entries ?? []).filter { !removed.contains($0.path) }
        let extra = unmeasuredDirs
        Section {
            if let s = scan, done {
                if entries.isEmpty && extra.isEmpty {
                    note("No folders here.")
                }
                ForEach(entries.prefix(30)) { e in
                    folderRow(name: e.name, path: e.path, bytes: e.bytes, total: max(s.totalBytes, 1), detail: nil)
                }
            } else if let s = scan, s.status == "error" {
                Text(s.error ?? "Scan failed").font(.system(size: 13)).foregroundStyle(Theme.crit).padding(14).cardRow()
            } else if stoppedLocally || scan?.status == "cancelled" {
                stoppedCard
            } else if scan != nil {
                runningCard
            } else if error == nil {
                HStack(spacing: 10) { ProgressView(); Text("Starting scan…").font(.system(size: 14)) }.padding(14).cardRow()
            }
            ForEach(extra) { e in
                folderRow(name: e.name, path: e.path, bytes: nil, total: nil,
                          detail: done ? "not measured · other filesystem" : "measuring…")
            }
        } header: {
            sectionHeader("Folders", trailing: done ? scan.map { Fmt.bytes($0.totalBytes) } : nil)
        } footer: {
            if let f = scan?.finishedAt.flatMap(Fmt.date), done {
                Text("Scanned \(Fmt.relative(f)) · only this filesystem").font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
        }
    }

    private func folderRow(name: String, path: String, bytes: UInt64?, total: UInt64?, detail: String?) -> some View {
        let target = DeleteTarget(path: path, name: name, isDir: true, bytes: bytes, inUse: inUseByPath[path])
        return NavigationLink { DiskUsageView(server: server, path: path) } label: {
            FSRow(icon: "folder.fill", iconColor: Theme.accent.opacity(0.8), name: name, bytes: bytes, total: total,
                  detail: detail, warning: inUseByPath[path].map { "In use: \($0)" })
        }
        .cardRow()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteButton(target) }
        .contextMenu { copyButton(path); deleteButton(target) }
    }

    @ViewBuilder private var filesSection: some View {
        Section {
            if let l = listing {
                let files = l.entries.filter { !$0.isDir && !removed.contains($0.path) }.sorted { $0.bytes > $1.bytes }
                if files.isEmpty {
                    note("No files in this folder.")
                }
                ForEach(files) { e in fileRow(e) }
                if l.truncated {
                    Text("Only the first \(l.entries.count) entries are shown.").font(.system(size: 12)).foregroundStyle(Theme.text3).padding(14).cardRow()
                }
            } else if let listingNote {
                note(listingNote)
            } else if error == nil {
                HStack(spacing: 10) { ProgressView(); Text("Listing files…").font(.system(size: 14)).foregroundStyle(Theme.text2) }.padding(14).cardRow()
            }
        } header: {
            let n = listing?.entries.filter { !$0.isDir && !removed.contains($0.path) }.count
            sectionHeader("Files", trailing: n.map { "\($0)" })
        } footer: {
            if listing != nil {
                Text("Tap a file to view or edit it. Swipe left or long-press to delete.").font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
        }
    }

    private func fileRow(_ e: FSEntry) -> some View {
        let target = DeleteTarget(path: e.path, name: e.name, isDir: false, bytes: e.bytes, inUse: e.inUse)
        return NavigationLink { FileEditorView(server: server, path: e.path) } label: {
            FSRow(icon: "link", iconColor: Theme.text3, fileName: e.type == "symlink" ? nil : e.name, name: e.name, bytes: e.bytes, total: nil,
                  detail: [Fmt.ago(e.mtime), e.owner, e.mode].filter { !$0.isEmpty }.joined(separator: " · "),
                  warning: e.inUse.map { "In use: \($0)" })
        }
        .cardRow()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteButton(target) }
        .contextMenu { copyButton(e.path); deleteButton(target) }
    }

    private func largestSection(_ files: [DiskEntry]) -> some View {
        Section {
            ForEach(files.prefix(15)) { f in
                let target = DeleteTarget(path: f.path, name: f.name, isDir: false, bytes: f.bytes, inUse: inUseByPath[f.path])
                NavigationLink { FileEditorView(server: server, path: f.path) } label: {
                    FSRow(icon: "doc.fill", iconColor: Theme.text3, fileName: f.name, name: f.name, bytes: f.bytes, total: nil, detail: f.path,
                          warning: inUseByPath[f.path].map { "In use: \($0)" })
                }
                .cardRow()
                .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteButton(target) }
                .contextMenu { copyButton(f.path); deleteButton(target) }
            }
        } header: {
            sectionHeader("Largest files", trailing: "over 50 MB")
        }
    }

    private func deleteButton(_ t: DeleteTarget) -> some View {
        Button(role: .destructive) { pendingDelete = t } label: { Label("Delete…", systemImage: "trash") }
            .tint(Theme.crit)
    }

    private func copyButton(_ path: String) -> some View {
        Button { UIPasteboard.general.string = path } label: { Label("Copy path", systemImage: "doc.on.doc") }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.text2).padding(14).frame(maxWidth: .infinity, alignment: .leading).cardRow()
    }

    private var stoppedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "stop.circle").foregroundStyle(Theme.text2).font(.system(size: 18))
                Text("Scan stopped").font(.system(size: 14, weight: .medium))
                Spacer()
                Button { Task { await start(force: true) } } label: {
                    Label("Scan again", systemImage: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                }
            }
            if let stopNote {
                Text(stopNote).font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
        }
        .padding(14).cardRow()
    }

    private var runningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                Text("Measuring folders…").font(.system(size: 14, weight: .medium))
                Spacer()
            }
            if let started = scanStart {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let secs = max(0, Int(ctx.date.timeIntervalSince(started)))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "timer")
                            Text("Running for \(Fmt.elapsed(secs))").font(Theme.mono(13).weight(.semibold))
                            Spacer()
                            Text("started \(started.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                        }
                        .foregroundStyle(secs > 600 ? Theme.warn : Theme.text)
                        if secs > 600 {
                            Text("This is taking unusually long. Stop it and scan a smaller folder, or check the connection.")
                                .font(.system(size: 12)).foregroundStyle(Theme.warn)
                        }
                    }
                }
            }
            if let pollError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "wifi.exclamationmark")
                    Text("No answer from the server (\(pollFailures)×): \(pollError). Retrying…")
                }
                .font(.system(size: 12)).foregroundStyle(Theme.warn)
            } else {
                Text("Large disks can take a few minutes. It runs at low priority on the server; you can browse the folders below meanwhile.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            IndeterminateBar(color: Theme.accent)
            Button(role: .destructive) { Task { await stopScan() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    Text("Stop scan")
                }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.crit)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Theme.crit.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(stopping)
        }
        .padding(14).cardRow()
    }

    // MARK: loading

    private var scanStart: Date? { scan.flatMap { Fmt.date($0.startedAt) } ?? localStart }

    private func load(force: Bool) async {
        async let a: () = start(force: force)
        async let b: () = loadListing()
        _ = await (a, b)
    }

    private func loadListing() async {
        listingNote = nil
        do {
            listing = try await store.api(for: server).get("/v1/fs/list?path=\(fsQuery(path))", timeout: .seconds(30))
        } catch let e as AgentAPI.HTTPError where (e.status == 404 && e.message.isEmpty) || e.status == 405 {
            listingNote = "Browsing files needs agent 0.3.3 on this server. Use ··· › Update agent."
        } catch let e as AgentAPI.HTTPError {
            listingNote = e.message
        } catch {
            listingNote = friendlyError(error)
        }
    }

    /// Stop always ends the wait on the phone at once; the server is told in the background.
    private func stopScan() async {
        stopping = true
        stoppedLocally = true
        stopNote = nil
        defer { stopping = false }
        do {
            _ = try await store.api(for: server).raw("DELETE", "/v1/disk/scan?path=\(fsQuery(path))", timeout: .seconds(20))
            if let s: DiskScan = try? await store.api(for: server).get("/v1/disk/scan?path=\(fsQuery(path))", timeout: .seconds(15)) { scan = s }
        } catch let e as AgentAPI.HTTPError where e.status == 404 || e.status == 405 {
            stopNote = "The agent on this server is older than 0.3.1 and cannot stop a scan. Update it with ··· › Update agent; updating also ends the old scan."
        } catch {
            stopNote = "Stopped on the phone, but the server did not confirm: \(friendlyError(error)). The scan ends by itself on the server after at most 15 minutes."
        }
    }

    private func start(force: Bool) async {
        error = nil
        notice = nil
        stoppedLocally = false
        stopNote = nil
        pollFailures = 0
        pollError = nil
        localStart = .now
        if force { removed = [] }
        let api = store.api(for: server)
        struct Body: Encodable { let path: String; let force: Bool }
        do {
            let data = try await api.send("POST", "/v1/disk/scan", Body(path: path, force: force), timeout: .seconds(30))
            scan = try JSON.decoder.decode(DiskScan.self, from: data)
        } catch let e as AgentAPI.HTTPError where e.status == 404 || e.status == 405 {
            error = "This server runs an older agent. Use ··· › Update agent, then try again."
            return
        } catch {
            self.error = friendlyError(error)
            return
        }
        if path == "/", docker == nil || force {
            Task { docker = try? await api.get("/v1/disk/docker", timeout: .seconds(300)) }
        }
        guard !polling else { return }
        polling = true
        defer { polling = false }
        while scan?.status == "running", !stoppedLocally, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if stoppedLocally { break }
            do {
                let s: DiskScan = try await api.get("/v1/disk/scan?path=\(fsQuery(path))", timeout: .seconds(20))
                if stoppedLocally { break }
                scan = s
                pollFailures = 0
                pollError = nil
            } catch let e as AgentAPI.HTTPError where e.status == 404 {
                // the agent forgot the scan (it restarted or was updated)
                stoppedLocally = true
                stopNote = "The server no longer has this scan (the agent restarted). Start it again."
            } catch {
                pollFailures += 1
                pollError = friendlyError(error)
            }
        }
    }

    // MARK: delete

    private func performDelete(_ t: DeleteTarget) async {
        deleting = true
        defer { deleting = false }
        // the sheet already showed the in-use warning, so a confirmed delete may use force
        let force = t.force || t.inUse != nil
        var query = "/v1/fs?path=\(fsQuery(t.path))"
        if force { query += "&force=1" }
        do {
            let data = try await store.api(for: server).raw("DELETE", query, timeout: .seconds(600))
            let res = try JSON.decoder.decode(FSDeleteResult.self, from: data)
            removed.insert(t.path)
            pendingDelete = nil
            error = nil
            notice = "Deleted \(t.name) · \(Fmt.bytes(res.freedBytes)) freed"
            await loadListing()
        } catch let e as AgentAPI.HTTPError where e.status == 409 {
            // the server knows a reason the list did not: show it and ask again
            var again = t
            again.inUse = e.message.replacingOccurrences(of: "in use: ", with: "")
            again.force = true
            pendingDelete = again
        } catch let e as AgentAPI.HTTPError where e.status == 404 && e.message.isEmpty || e.status == 405 {
            pendingDelete = nil
            error = "Deleting needs agent 0.3.3 on this server. Use ··· › Update agent."
        } catch {
            pendingDelete = nil
            self.error = friendlyError(error)
        }
    }
}

// MARK: - rows

/// A folder or file line: name, optional size with share bar, a detail line and a red warning.
struct FSRow: View {
    let icon: String
    let iconColor: Color
    var fileName: String? = nil   // shows a type badge (TSX, PDF…) instead of the symbol
    let name: String
    var bytes: UInt64? = nil
    var total: UInt64? = nil
    var detail: String? = nil
    var warning: String? = nil

    var body: some View {
        let share = (bytes != nil && (total ?? 0) > 0) ? Double(bytes!) / Double(total!) : nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let fileName {
                    FileBadge(name: fileName)
                } else {
                    Image(systemName: icon).foregroundStyle(iconColor).font(.system(size: 15)).frame(width: 30, height: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(Theme.mono(10)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if let bytes {
                    Text(Fmt.bytes(bytes)).font(Theme.mono(13, .medium)).foregroundStyle(Theme.text)
                } else {
                    Text("—").font(Theme.mono(13)).foregroundStyle(Theme.text3)
                }
                if let share {
                    Text(String(format: "%.0f%%", share * 100)).font(Theme.mono(11)).foregroundStyle(Theme.text3).frame(width: 34, alignment: .trailing)
                }
            }
            if let share {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.border)
                        Capsule().fill(Theme.accent).frame(width: max(2, g.size.width * share))
                    }
                }
                .frame(height: 4)
            }
            if let warning {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(warning)
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.crit).lineLimit(2)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// A list row that looks like one line of a `ListCard`.
    func cardRow() -> some View {
        listRowBackground(Theme.surface).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
    }

    /// A list row with no card behind it (headers, banners, buttons).
    func plainRow() -> some View {
        listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
    }
}

// MARK: - delete confirmation

struct DeleteTarget: Identifiable {
    let path: String
    let name: String
    let isDir: Bool
    let bytes: UInt64?
    var inUse: String?
    var force = false
    var id: String { path }
}

struct DeleteSheet: View {
    let target: DeleteTarget
    let busy: Bool
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @FocusState private var focused: Bool

    private var ready: Bool { !target.isDir || typed == target.name }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: target.isDir ? "folder.fill" : "doc.fill").font(.system(size: 30)).foregroundStyle(Theme.crit)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(target.name).font(.system(size: 17, weight: .semibold))
                            Text(target.path).font(Theme.mono(11)).foregroundStyle(Theme.text3).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            fact("Size", target.bytes.map(Fmt.bytes) ?? "not measured")
                            fact("Removes", target.isDir ? "the folder and everything inside it" : "this file")
                        }
                    }
                    if let u = target.inUse {
                        Banner(icon: "exclamationmark.triangle.fill", title: "In use on the server",
                               text: "\(u). Deleting it can break a running container or program.", color: Theme.crit)
                    }
                    Banner(icon: "trash.fill", title: "Deletes are permanent",
                           text: "There is no trash on the server. The space is freed at once and the data cannot be recovered.", color: Theme.warn)
                    if target.isDir {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Type the folder name to confirm").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2)
                            TextField(target.name, text: $typed)
                                .font(Theme.mono(15))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .padding(12)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ready ? Theme.crit : Theme.border))
                                .focused($focused)
                        }
                    }
                    Button { onConfirm() } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? "Deleting…" : target.force ? "Delete anyway" : (target.isDir ? "Delete folder" : "Delete file"))
                        }
                    }
                    .buttonStyle(DangerButtonStyle())
                    .disabled(!ready || busy)
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("Delete?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(busy)
    }

    private func fact(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 13)).foregroundStyle(Theme.text2).frame(width: 70, alignment: .leading)
            Text(v).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
        }
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.crit, in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
