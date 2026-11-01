import SwiftUI

/// Percent-encodes a path for a `?path=` query. Go's query parser turns a bare
/// "+" into a space, so the set is stricter than `.urlQueryAllowed`.
func fsQuery(_ p: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?#;")
    return p.addingPercentEncoding(withAllowedCharacters: allowed) ?? p
}

/// Text viewer and editor for one file on the server.
/// View mode: numbered lines, find with highlight. Edit mode: monospaced editor,
/// save with conflict detection (the agent refuses when the file changed meanwhile).
struct FileEditorView: View {
    @Environment(ServerStore.self) private var store
    let server: ServerRecord
    let path: String

    @State private var file: FSFile?
    @State private var lines: [String] = []
    @State private var text = ""
    @State private var editing = false
    @State private var loading = true
    @State private var error: String?
    @State private var saving = false
    @State private var saved: String?
    @State private var conflict = false
    @State private var query = ""
    @State private var searching = false
    @State private var matches: [Int] = []
    @State private var current = 0
    @State private var showDiscard = false
    @FocusState private var searchFocused: Bool

    private var name: String { (path as NSString).lastPathComponent }
    private var dirty: Bool { editing && text != (file?.content ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            if let f = file { infoBar(f) }
            if searching && !editing { searchBar }
            if let saved {
                Label(saved, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ok)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.ok.opacity(0.1))
            }
            if loading {
                VStack(spacing: 10) { ProgressView(); Text("Loading…").font(.system(size: 13)).foregroundStyle(Theme.text2) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let f = file {
                if f.binary {
                    placeholder(icon: "doc.zipper", title: "Binary file", text: "This file is not text, so it cannot be shown or edited here.")
                } else if editing {
                    editor
                } else {
                    viewer
                }
            } else if let error {
                ScrollView {
                    Banner(icon: "exclamationmark.triangle.fill", title: "Could not open the file", text: error, color: Theme.crit).padding(20)
                }
            }
        }
        .background(Theme.bg)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(editing)
        .toolbar { toolbarContent }
        .task { await load() }
        .alert("The file changed on the server", isPresented: $conflict) {
            Button("Reload and lose my changes") { Task { await load() } }
            Button("Overwrite anyway", role: .destructive) { Task { await save(overwrite: true) } }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("\(name) was modified since you opened it. Reload to see the new version, or overwrite it with your copy. A backup of the server's version is kept either way.")
        }
        .confirmationDialog("Discard your changes?", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { text = file?.content ?? ""; editing = false }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if editing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { if dirty { showDiscard = true } else { editing = false } }.disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await save(overwrite: false) } } label: {
                    if saving { ProgressView() } else { Text("Save").bold() }
                }
                .disabled(!dirty || saving)
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { searching.toggle() }
                    if searching { searchFocused = true } else { query = "" }
                } label: { Image(systemName: "magnifyingglass") }
                .disabled(file == nil || file?.binary == true)
                .accessibilityLabel("Find in file")
                if let f = file, f.editable {
                    Button("Edit") { text = f.content; saved = nil; editing = true }
                }
                Menu {
                    Button { Task { await load() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    Button { UIPasteboard.general.string = path } label: { Label("Copy path", systemImage: "doc.on.doc") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More")
            }
        }
    }

    // MARK: header

    private func infoBar(_ f: FSFile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(f.path).font(Theme.mono(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Text("\(Fmt.bytes(f.bytes)) · \(lines.count) lines · modified \(Fmt.ago(f.mtime)) · \(f.owner):\(f.group) \(f.mode)")
                .font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1)
            if let why = readOnlyReason(f) {
                Label(why, systemImage: "lock.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.warn)
            }
            if let u = f.inUse {
                Label("In use: \(u)", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.crit)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func readOnlyReason(_ f: FSFile) -> String? {
        if f.binary { return nil }
        if f.truncated { return "Too big to edit here: showing the last 512 KB" }
        if f.editable { return nil }
        if let p = f.protected { return "Protected system path (\(p)): read-only" }
        if f.bytes > 64 * 1024 { return "Files over 64 KB are read-only in the app" }
        return "Read-only"
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3).font(.system(size: 13))
            TextField("Find in file", text: $query)
                .font(Theme.mono(13))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { step(1) }
            if !query.isEmpty {
                Text(matches.isEmpty ? "0" : "\(current + 1)/\(matches.count)").font(Theme.mono(11)).foregroundStyle(Theme.text2)
            }
            Button { step(-1) } label: { Image(systemName: "chevron.up") }.disabled(matches.isEmpty).accessibilityLabel("Previous match")
            Button { step(1) } label: { Image(systemName: "chevron.down") }.disabled(matches.isEmpty).accessibilityLabel("Next match")
            Button { query = ""; searching = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3) }.accessibilityLabel("Close search")
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.surface2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .onChange(of: query) { _, q in recomputeMatches(q) }
    }

    private func placeholder(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 36)).foregroundStyle(Theme.text3)
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: viewer and editor

    private var lineNumberWidth: CGFloat { CGFloat(max(2, String(lines.count).count)) * 7.5 + 6 }

    private var viewer: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(i + 1)").font(Theme.mono(11)).foregroundStyle(Theme.text3)
                                .frame(width: lineNumberWidth, alignment: .trailing)
                            Text(highlighted(line)).font(Theme.mono(12.5)).foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 1.5).padding(.horizontal, 10)
                        .background(isCurrent(i) ? Theme.warn.opacity(0.18) : .clear)
                        .id(i)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Theme.logBg)
            .onChange(of: current) { _, c in
                if matches.indices.contains(c) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(matches[c], anchor: .center) } }
            }
            .onChange(of: matches) { _, m in
                current = 0
                if let first = m.first { proxy.scrollTo(first, anchor: .center) }
            }
        }
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(Theme.mono(13))
            .foregroundStyle(Theme.text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.asciiCapable)
            .scrollContentBackground(.hidden)
            .background(Theme.logBg)
            .padding(.horizontal, 6)
    }

    private func isCurrent(_ line: Int) -> Bool {
        matches.indices.contains(current) && matches[current] == line
    }

    private func highlighted(_ line: String) -> AttributedString {
        var a = AttributedString(line)
        guard !query.isEmpty else { return a }
        var from = line.startIndex
        while from < line.endIndex, let r = line.range(of: query, options: [.caseInsensitive], range: from..<line.endIndex) {
            if let ar = Range(r, in: a) {
                a[ar].backgroundColor = Theme.warn.opacity(0.55)
                a[ar].foregroundColor = Theme.bg
            }
            from = r.upperBound
        }
        return a
    }

    private func recomputeMatches(_ q: String) {
        guard !q.isEmpty else { matches = []; current = 0; return }
        matches = lines.indices.filter { lines[$0].range(of: q, options: .caseInsensitive) != nil }
    }

    private func step(_ d: Int) {
        guard !matches.isEmpty else { return }
        current = (current + d + matches.count) % matches.count
    }

    // MARK: loading and saving

    private func load() async {
        loading = true
        error = nil
        saved = nil
        defer { loading = false }
        do {
            let f: FSFile = try await store.api(for: server).get("/v1/fs/read?path=\(fsQuery(path))", timeout: .seconds(60))
            file = f
            text = f.content
            lines = f.content.components(separatedBy: "\n")
            editing = false
            recomputeMatches(query)
        } catch let e as AgentAPI.HTTPError where (e.status == 404 && e.message.isEmpty) || e.status == 405 {
            error = "Viewing files needs agent 0.3.3 on this server. Use ··· › Update agent."
        } catch {
            self.error = friendlyError(error)
        }
    }

    /// Sends the buffer with the hash of the version we opened; the agent keeps a
    /// backup and refuses (409) when the file changed meanwhile.
    private func save(overwrite: Bool) async {
        guard let f = file else { return }
        saving = true
        defer { saving = false }
        let api = store.api(for: server)
        struct Body: Encodable { let path: String; let content: String; let expectSha256: String }
        do {
            var sha = f.sha256 ?? ""
            if overwrite {
                let fresh: FSFile = try await api.get("/v1/fs/read?path=\(fsQuery(path))", timeout: .seconds(60))
                sha = fresh.sha256 ?? ""
            }
            let data = try await api.send("PUT", "/v1/fs/write", Body(path: path, content: text, expectSha256: sha), timeout: .seconds(60))
            let res = try JSON.decoder.decode(FSWriteResult.self, from: data)
            var nf = f
            nf.content = text
            nf.sha256 = res.sha256
            nf.mtime = res.mtime
            nf.bytes = res.bytes
            file = nf
            lines = text.components(separatedBy: "\n")
            editing = false
            error = nil
            saved = "Saved" + (res.backup.map { " · previous version kept as \(($0 as NSString).lastPathComponent)" } ?? "")
            recomputeMatches(query)
        } catch let e as AgentAPI.HTTPError where e.status == 409 {
            conflict = true
        } catch {
            self.error = friendlyError(error)
        }
    }
}
