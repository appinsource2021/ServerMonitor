import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - Team tab (super admin)

struct TeamView: View {
    @Environment(ServerStore.self) private var store
    @State private var showInvite = false
    @State private var showRelaySetup = false
    @State private var shownInvite: InviteShare?
    @State private var message: String?

    private var team: TeamStore { store.team }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if !RelaySettings.configured {
                        relayIntro
                    } else {
                        if let e = team.error {
                            Banner(icon: "wifi.exclamationmark", title: "Relay not reachable", text: e, color: Theme.crit)
                        }
                        serversSection
                        membersSection
                        if !team.pending.isEmpty { pendingSection }
                        Banner(icon: "lock.fill", title: "Members never get SSH access",
                               text: "Hidden containers, services and logs are filtered on each server, so they never reach a member's phone.",
                               color: Theme.accent)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await team.load(); await team.sync(store: store) }
            .task { await team.load(); await team.sync(store: store) }
            .sheet(isPresented: $showInvite) { InviteView() }
            .sheet(isPresented: $showRelaySetup) { RelaySetupView() }
            .sheet(item: $shownInvite) { inv in InviteQRSheet(share: inv) }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Team").font(.system(size: 34, weight: .bold)).tracking(-0.6)
                Text("Only you see this tab · Super admin").font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
            Spacer()
            if RelaySettings.configured {
                Button { showInvite = true } label: {
                    Image(systemName: "person.badge.plus").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.bg)
                        .frame(width: 44, height: 44)
                        .background(Theme.accent, in: Circle())
                }
                .accessibilityLabel("Invite user")
                .disabled(team.state?.servers.isEmpty ?? true)
            }
        }
        .padding(.top, 8)
    }

    private var relayIntro: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 28)).foregroundStyle(Theme.accent)
                Text("Share servers without SSH").font(.system(size: 17, weight: .semibold))
                Text("Team members reach your servers through a relay that you run yourself, on any Linux machine you choose. Servers connect out to it, so no port is opened on them.")
                    .font(.system(size: 14)).foregroundStyle(Theme.text2)
                Button("Set up relay") { showRelaySetup = true }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var serversSection: some View {
        VStack(spacing: 8) {
            HStack {
                SectionHeader(text: "Servers on the relay")
                Button("Relay") { showRelaySetup = true }.font(.system(size: 13, weight: .medium))
            }
            ListCard {
                ForEach(store.sshServers.filter(\.installed)) { s in
                    ServerRelayRow(server: s, relayServer: team.state?.servers.first { $0.id == s.relayServerID }) {
                        do { try await team.enroll(s, store: store) } catch { message = error.localizedDescription }
                    }
                }
            }
        }
    }

    private var membersSection: some View {
        VStack(spacing: 8) {
            SectionHeader(text: "Members · \(team.members.count)")
            if team.members.isEmpty {
                Card { Text("No members yet. Tap + to invite someone.").font(.system(size: 14)).foregroundStyle(Theme.text2) }
            } else {
                ListCard {
                    ForEach(team.members) { m in
                        NavigationLink { MemberAccessView(member: m) } label: { MemberRow(member: m, servers: team.state?.servers ?? []) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var pendingSection: some View {
        VStack(spacing: 8) {
            SectionHeader(text: "Pending invites · \(team.pending.count)")
            ListCard {
                ForEach(team.pending) { m in
                    HStack(spacing: 12) {
                        Image(systemName: "clock").foregroundStyle(Theme.warn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(m.name) · \(m.role.capitalized)").font(.system(size: 15))
                            Text(m.inviteExpiresAt.flatMap(Fmt.date).map { "Expires \(Fmt.relative($0))" } ?? "")
                                .font(.system(size: 12)).foregroundStyle(Theme.text2)
                        }
                        Spacer()
                        Button("Cancel", role: .destructive) {
                            Task { try? await team.remove(m, store: store) }
                        }
                        .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
            Text("The QR code is shown only once when you create an invite. To share again, cancel and invite anew.")
                .font(.system(size: 12)).foregroundStyle(Theme.text2).padding(.horizontal, 4)
        }
    }
}

struct ServerRelayRow: View {
    let server: ServerRecord
    let relayServer: RelayServer?
    let connect: () async -> Void
    @State private var busy = false

    var body: some View {
        HStack(spacing: 12) {
            StatusMark(health: relayServer == nil ? .unknown : relayServer!.online ? .healthy : .critical)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.system(size: 15, weight: .medium))
                Text(statusText).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            if relayServer == nil || !(relayServer?.online ?? false) {
                Button {
                    busy = true
                    Task { await connect(); busy = false }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text(relayServer == nil ? "Connect" : "Reconnect") }
                }
                .font(.system(size: 13, weight: .semibold))
                .disabled(busy)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var statusText: String {
        guard let r = relayServer else { return "Not shared with the team" }
        if r.online { return "Connected to relay" }
        if (server.agentVersion ?? "0") < "0.2.0" { return "Update the agent to 0.2 (··· › Update agent)" }
        return "Waiting for the agent to connect"
    }
}

struct MemberRow: View {
    let member: RelayMember
    let servers: [RelayServer]
    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: member.name, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                Text(scopeSummary).font(Theme.mono(11)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                RoleChip(role: member.role)
                Text(seen).font(.system(size: 11)).foregroundStyle(member.needsSync ? Theme.warn : Theme.text2)
            }
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .contentShape(Rectangle())
    }

    private var scopeSummary: String {
        if member.role == "admin" { return "All containers" }
        let parts = member.scopes.compactMap { sid, pats -> String? in
            guard let name = servers.first(where: { $0.id == sid })?.name else { return nil }
            return "\(name) · \(pats.isEmpty ? "nothing" : pats.joined(separator: " "))"
        }
        return parts.isEmpty ? "No servers" : parts.sorted().joined(separator: "  ")
    }

    private var seen: String {
        if member.needsSync { return "Activating…" }
        if let d = Fmt.date(member.lastSeen) { return "Active \(Fmt.relative(d))" }
        return "Never connected"
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 38
    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let palette: [Color] = [Theme.accent, Theme.ok, Theme.warn, Color(hex: 0xB892FF), Color(hex: 0x4FD1C5)]
        let c = palette[abs(name.hashValue) % palette.count]
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.37, weight: .semibold))
            .foregroundStyle(Theme.bg)
            .frame(width: size, height: size)
            .background(c, in: Circle())
            .accessibilityHidden(true)
    }
}

struct RoleChip: View {
    let role: String
    var body: some View {
        let color: Color = role == "admin" ? Theme.accent : role == "operator" ? Theme.warn : Theme.text2
        Text(role.capitalized)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Relay setup

/// Hands out the one-file installer: whoever runs it on a machine makes that machine a relay.
struct RelayInstallerCard: View {
    private let steps = [
        "Point a domain name at the machine that will be the relay.",
        "Send it this file, for example by AirDrop to a Mac and then scp.",
        "On that machine, run the command below and answer its questions.",
        "Enter the address and token it prints in the fields below.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "Install your relay")
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(i + 1)").font(Theme.mono(13, .medium)).foregroundStyle(Theme.accent)
                            Text(s).font(.system(size: 14)).foregroundStyle(Theme.text)
                        }
                    }
                    Text("sudo sh srvmon-relay-setup.sh")
                        .font(Theme.mono(13)).foregroundStyle(Theme.text).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.logBg, in: RoundedRectangle(cornerRadius: 10))
                    if let file = BundledAgent.relayInstallerURL {
                        ShareLink(item: file) { Label("Share installer", systemImage: "square.and.arrow.up") }
                            .buttonStyle(PrimaryButtonStyle(secondary: true))
                    } else {
                        Text("The installer is missing from this build.").font(.system(size: 13)).foregroundStyle(Theme.crit)
                    }
                }
            }
        }
    }
}

struct RelaySetupView: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var url = RelaySettings.url
    @State private var token = RelaySettings.adminToken ?? ""
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RelayInstallerCard()
                    SectionHeader(text: "Connect this app")
                    ListCard {
                        field("Address", text: $url, mono: true, keyboard: .URL)
                        Rectangle().fill(Theme.border).frame(height: 1)
                        HStack(spacing: 12) {
                            Text("Admin token").font(.system(size: 15)).frame(width: 100, alignment: .leading)
                            SecureField("from the relay's first start", text: $token).font(Theme.mono(14))
                        }
                        .padding(.horizontal, 14).frame(minHeight: 48)
                    }
                    Text("The installer prints the address and the admin token when it finishes. The token stays in this iPhone's Keychain.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2).padding(.horizontal, 4)
                    if let result { Text(result).font(.system(size: 13)).foregroundStyle(result.hasPrefix("✓") ? Theme.ok : Theme.crit) }
                    Button {
                        Task { await save() }
                    } label: {
                        HStack { if testing { ProgressView().tint(Theme.bg) }; Text("Test & save") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(testing || !url.hasPrefix("https://") || token.count < 24)
                    .opacity(url.hasPrefix("https://") && token.count >= 24 ? 1 : 0.5)
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("Relay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationBackground(Theme.bg)
    }

    private func field(_ label: String, text: Binding<String>, mono: Bool, keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 15)).frame(width: 100, alignment: .leading)
            TextField("https://…", text: text).font(mono ? Theme.mono(14) : .system(size: 15))
                .keyboardType(keyboard).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        .padding(.horizontal, 14).frame(minHeight: 48)
    }

    private func save() async {
        testing = true
        defer { testing = false }
        let base = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        do {
            let _: RelayState = try await RelayClient(baseURL: base, bearer: token).json("GET", "/admin/v1/state")
            RelaySettings.url = base
            RelaySettings.adminToken = token
            result = "✓ Connected"
            await store.team.load()
            dismiss()
        } catch {
            result = error.localizedDescription
        }
    }
}

// MARK: - Invite

struct ScopeDraft: Identifiable {
    let id: String // relay server id
    let name: String
    var enabled: Bool
    var patterns: String

    var list: [String] { patterns.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).map(String.init) }
}

struct InviteShare: Identifiable {
    let id = UUID()
    let name: String
    let role: String
    let link: String
    let expires: String
}

struct InviteView: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role = "viewer"
    @State private var scopes: [ScopeDraft] = []
    @State private var creating = false
    @State private var error: String?
    @State private var share: InviteShare?

    var body: some View {
        NavigationStack {
            if let share {
                InviteQRContent(share: share) { dismiss() }
            } else {
                form
            }
        }
        .presentationBackground(Theme.bg)
        .onAppear {
            scopes = (store.team.state?.servers ?? []).map { ScopeDraft(id: $0.id, name: $0.name, enabled: true, patterns: "") }
        }
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && scopes.contains(where: \.enabled)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ListCard {
                    HStack(spacing: 12) {
                        Text("Name").font(.system(size: 15)).frame(width: 70, alignment: .leading)
                        TextField("Mehmet Yılmaz", text: $name).font(.system(size: 15)).textInputAutocapitalization(.words)
                    }
                    .padding(.horizontal, 14).frame(minHeight: 48)
                }
                RolePicker(role: $role)
                ScopeEditor(scopes: $scopes, role: role)
                if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.crit) }
                Button {
                    Task { await create() }
                } label: {
                    HStack { if creating { ProgressView().tint(Theme.bg) }; Text("Create invite") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!valid || creating)
                .opacity(valid ? 1 : 0.5)
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle("Invite")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private func create() async {
        creating = true
        defer { creating = false }
        var map: [String: [String]] = [:]
        for s in scopes where s.enabled { map[s.id] = s.list }
        do {
            let r = try await store.team.invite(name: name.trimmingCharacters(in: .whitespaces), role: role, scopes: map)
            share = InviteShare(name: name, role: role, link: r.link, expires: r.expires)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RolePicker: View {
    @Binding var role: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "Role")
            Segmented(options: [("admin", "Admin"), ("operator", "Operator"), ("viewer", "Viewer")], selection: $role)
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    perm("Server health: CPU, memory, disk", true)
                    perm("Containers in scope and their status", true)
                    perm("Start, stop, restart containers", role != "viewer")
                    perm("Container logs and system services", role == "admin")
                    perm("All containers, scope ignored", role == "admin")
                }
            }
        }
    }

    private func perm(_ t: String, _ on: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: on ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(on ? Theme.ok : Theme.text3)
            Text(t).font(.system(size: 14)).foregroundStyle(on ? Theme.text : Theme.text3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(t): \(on ? "allowed" : "not allowed")")
    }
}

struct ScopeEditor: View {
    @Binding var scopes: [ScopeDraft]
    let role: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "Access scope")
            ForEach($scopes) { $s in
                VStack(alignment: .leading, spacing: 0) {
                    Toggle(isOn: $s.enabled) { Text(s.name).font(.system(size: 15, weight: .medium)) }
                        .tint(Theme.ok)
                        .padding(.horizontal, 14).frame(minHeight: 48)
                    if s.enabled && role != "admin" {
                        Rectangle().fill(Theme.border).frame(height: 1)
                        HStack(spacing: 8) {
                            Text("Containers").font(.system(size: 13)).foregroundStyle(Theme.text2)
                            TextField("erp-*  n8n", text: $s.patterns)
                                .font(Theme.mono(14))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        .padding(.horizontal, 14).frame(minHeight: 44)
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
            }
            Text(role == "admin"
                 ? "Admins see every container on the servers you switch on."
                 : "Patterns match container name, image or compose project. * is a wildcard: erp-* shows ERP-Backend, ERP-DB… Empty means no containers, only server health.")
                .font(.system(size: 12)).foregroundStyle(Theme.text2).padding(.horizontal, 4)
        }
    }
}

struct InviteQRSheet: View {
    @Environment(\.dismiss) private var dismiss
    let share: InviteShare
    var body: some View {
        NavigationStack { InviteQRContent(share: share) { dismiss() } }.presentationBackground(Theme.bg)
    }
}

struct InviteQRContent: View {
    let share: InviteShare
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 14) {
                    QRCode(text: share.link)
                        .frame(width: 220, height: 220)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("Invite QR code for \(share.name)")
                    VStack(spacing: 4) {
                        Text("Scan with the iPhone camera").font(.system(size: 15, weight: .semibold))
                        Text("Opens Server Monitor and joins as \(share.role.capitalized). Single use · \(expiry)")
                            .font(.system(size: 12)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
                    }
                    HStack(spacing: 8) {
                        Button {
                            UIPasteboard.general.string = share.link
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(PrimaryButtonStyle(secondary: true))
                        ShareLink(item: share.link, subject: Text("Server Monitor invite"),
                                  message: Text("Install Server Monitor, then open this link to join: ")) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
                .padding(20)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.border))
                Text("\(share.name) appears under Members after joining. Your app then activates them on each server automatically.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle("Invite \(share.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
    }

    private var expiry: String {
        Fmt.date(share.expires).map { "expires \(Fmt.relative($0))" } ?? "expires in 48 h"
    }
}

struct QRCode: View {
    let text: String
    var body: some View {
        if let img = Self.make(text) {
            Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
        } else {
            Color.white
        }
    }

    static func make(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Member access (edit / revoke)

struct MemberAccessView: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let member: RelayMember
    @State private var role = "viewer"
    @State private var scopes: [ScopeDraft] = []
    @State private var saving = false
    @State private var confirmRevoke = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Avatar(name: member.name, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(member.name).font(.system(size: 22, weight: .bold))
                        Text([member.role.capitalized, member.device, Fmt.date(member.lastSeen).map { "active \(Fmt.relative($0))" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 13)).foregroundStyle(Theme.text2)
                    }
                }
                RolePicker(role: $role)
                ScopeEditor(scopes: $scopes, role: role)
                if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.crit) }
                Button(role: .destructive) { confirmRevoke = true } label: {
                    Text("Revoke access").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.crit)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Theme.crit.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.crit.opacity(0.4)))
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await save() } } label: { saving ? AnyView(ProgressView()) : AnyView(Text("Save").bold()) }
                    .disabled(saving)
            }
        }
        .confirmationDialog("Revoke \(member.name)'s access?", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("Revoke", role: .destructive) {
                Task {
                    do { try await store.team.remove(member, store: store); dismiss() } catch { self.error = error.localizedDescription }
                }
            }
        } message: { Text("Their app loses access to every server immediately.") }
        .onAppear {
            role = member.role
            scopes = (store.team.state?.servers ?? []).map { s in
                let pats = member.scopes[s.id]
                return ScopeDraft(id: s.id, name: s.name, enabled: pats != nil, patterns: (pats ?? []).joined(separator: " "))
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var map: [String: [String]] = [:]
        for s in scopes where s.enabled { map[s.id] = s.list }
        do {
            try await store.team.update(member, role: role, scopes: map, store: store)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Joining (member)

struct JoinView: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let link: TeamJoin.Link
    @State private var joining = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "person.2.badge.key").font(.system(size: 44)).foregroundStyle(Theme.accent).padding(.top, 30)
                VStack(spacing: 6) {
                    Text("Join a team").font(.system(size: 24, weight: .bold))
                    Text("You were invited to monitor servers via \(URL(string: link.relay)?.host ?? link.relay).")
                        .font(.system(size: 14)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
                }
                if !store.sshServers.isEmpty {
                    Banner(icon: "exclamationmark.triangle", title: "This iPhone manages servers as admin",
                           text: "Joining adds the team's servers next to yours.", color: Theme.warn)
                }
                if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.crit).multilineTextAlignment(.center) }
                Spacer()
                Button {
                    Task {
                        joining = true
                        defer { joining = false }
                        do { try await store.join(link); dismiss() } catch { self.error = error.localizedDescription }
                    }
                } label: {
                    HStack { if joining { ProgressView().tint(Theme.bg) }; Text("Join") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(joining)
            }
            .padding(20)
            .background(Theme.bg)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationBackground(Theme.bg)
    }
}
