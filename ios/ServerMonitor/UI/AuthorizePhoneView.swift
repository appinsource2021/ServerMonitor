import SwiftUI
import UIKit

/// On the phone that already has the servers: put another iPhone's key on them, then hand
/// that iPhone the server list as a QR code. Opened by scanning its `srvmon://authorize` code.
struct AuthorizePhoneView: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let link: PhoneLink.Authorize

    @State private var selected: Set<UUID> = []
    @State private var running = false
    @State private var failures: [UUID: String] = [:]
    @State private var done: [UUID] = []       // servers the key is now on
    @State private var copied = false

    private var candidates: [ServerRecord] { store.sshServers.filter(\.installed).sorted { $0.name < $1.name } }
    private var isOwnKey: Bool { PhoneLink.keyCore(link.key) == PhoneLink.keyCore(AppIdentity.publicKeyLine) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Card(padding: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: "iphone.gen3").font(.system(size: 26)).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(link.name).font(.system(size: 16, weight: .semibold))
                                Text(PhoneLink.fingerprint(link.key)).font(Theme.mono(11)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    if isOwnKey {
                        Banner(icon: "exclamationmark.triangle.fill", title: "That is this iPhone's own key", text: "Scan the code on the other iPhone (Settings → This iPhone's SSH key).", color: Theme.warn)
                    } else if done.isEmpty {
                        Text("Its key goes into authorized_keys of the login user on the servers you pick, the same way this iPhone's key got there. No root is needed for a server monitored as a non-root user.")
                            .font(.system(size: 13)).foregroundStyle(Theme.text2)
                        serverList
                        Button {
                            Task { await run() }
                        } label: {
                            HStack(spacing: 8) {
                                if running { ProgressView().controlSize(.small).tint(Theme.bg) }
                                Text(running ? "Authorizing…" : "Authorize on \(selected.count) server\(selected.count == 1 ? "" : "s")")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(selected.isEmpty || running)
                        .opacity(selected.isEmpty ? 0.5 : 1)
                        if !failures.isEmpty { failureList }
                    } else {
                        resultCard
                        handover
                    }
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("Authorize iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { if selected.isEmpty { selected = Set(candidates.map(\.id)) } }
        }
        .presentationBackground(Theme.bg)
    }

    private var serverList: some View {
        VStack(spacing: 8) {
            SectionHeader(text: "Servers")
            if candidates.isEmpty {
                Card { Text("No servers on this iPhone yet.").font(.system(size: 13)).foregroundStyle(Theme.text2) }
            } else {
                ListCard {
                    ForEach(candidates) { s in
                        Toggle(isOn: Binding(get: { selected.contains(s.id) },
                                             set: { on in if on { selected.insert(s.id) } else { selected.remove(s.id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.system(size: 15))
                                Text("\(s.username)@\(s.host)" + (s.externalAgent == true ? " · existing agent" : ""))
                                    .font(Theme.mono(11)).foregroundStyle(Theme.text2)
                            }
                        }
                        .tint(Theme.ok)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                    }
                }
            }
        }
    }

    private var failureList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(candidates.filter { failures[$0.id] != nil }) { s in
                Text("\(s.name): \(failures[s.id] ?? "")").font(.system(size: 12)).foregroundStyle(Theme.crit)
            }
            Text("Fix the connection (Servers screen) and tap Authorize again; servers already done are kept.")
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
        }
    }

    private var resultCard: some View {
        let ok = candidates.filter { done.contains($0.id) }
        return Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Key added on \(ok.count) server\(ok.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ok)
                ForEach(ok) { s in Text(s.name).font(.system(size: 13)).foregroundStyle(Theme.text2) }
                ForEach(candidates.filter { failures[$0.id] != nil }) { s in
                    Text("\(s.name): \(failures[s.id] ?? "")").font(.system(size: 12)).foregroundStyle(Theme.crit)
                }
            }
        }
    }

    /// The server list for the other iPhone: scan with its camera, or send the link.
    private var handover: some View {
        let ok = candidates.filter { done.contains($0.id) }
        let importLink = PhoneLink.importLink(ok)
        return VStack(spacing: 14) {
            QRCode(text: importLink)
                .frame(width: 220, height: 220)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Server list for \(link.name)")
            VStack(spacing: 4) {
                Text("Now scan this with \(link.name)").font(.system(size: 15, weight: .semibold))
                Text("Its Server Monitor opens, adds these \(ok.count) server\(ok.count == 1 ? "" : "s") and connects with its own key.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                Button {
                    UIPasteboard.general.string = importLink
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(PrimaryButtonStyle(secondary: true))
                ShareLink(item: importLink, subject: Text("Server Monitor servers"),
                          message: Text("Open this link in Server Monitor to add the servers: ")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.border))
    }

    private func run() async {
        running = true
        let targets = candidates.filter { selected.contains($0.id) && !done.contains($0.id) }
        let fails = await store.authorize(key: link.key, on: targets)
        failures = fails
        let okNow = targets.filter { fails[$0.id] == nil }.map(\.id)
        if !okNow.isEmpty {
            done.append(contentsOf: okNow)
            if let i = store.authorizedPhones.firstIndex(where: { PhoneLink.keyCore($0.key) == PhoneLink.keyCore(link.key) }) {
                store.authorizedPhones[i].serverIDs = Array(Set(store.authorizedPhones[i].serverIDs + done))
                store.authorizedPhones[i].name = link.name
            } else {
                store.authorizedPhones.append(AuthorizedPhone(name: link.name, key: link.key, serverIDs: done))
            }
            store.savePhones()
        }
        running = false
    }
}

/// On the new phone: the servers another iPhone sent. Opened by scanning its `srvmon://import` code.
struct ImportServersView: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let link: PhoneLink.Import

    private func exists(_ e: PhoneLink.ServerExport) -> Bool {
        store.servers.contains { $0.host == e.h && $0.port == e.p && $0.username == e.u }
    }

    var body: some View {
        let fresh = link.servers.filter { !exists($0) }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Another iPhone shared these servers and has already put this iPhone's key on them. Nothing is installed; this iPhone just logs in with its own key.")
                        .font(.system(size: 13)).foregroundStyle(Theme.text2)
                    ListCard {
                        ForEach(link.servers, id: \.self) { e in
                            HStack(spacing: 12) {
                                Image(systemName: "server.rack").foregroundStyle(exists(e) ? Theme.text3 : Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.n.isEmpty ? e.h : e.n).font(.system(size: 15, weight: .medium))
                                    Text("\(e.u)@\(e.h)" + (e.p == 22 ? "" : ":\(e.p)") + (e.x == true ? " · existing agent" : ""))
                                        .font(Theme.mono(11)).foregroundStyle(Theme.text2)
                                }
                                Spacer()
                                if exists(e) { Text("already added").font(.system(size: 12)).foregroundStyle(Theme.text3) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                        }
                    }
                    Button(fresh.isEmpty ? "Nothing new to add" : "Add \(fresh.count) server\(fresh.count == 1 ? "" : "s")") {
                        store.importServers(link.servers)
                        dismiss()
                        Task { await store.refreshAll() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(fresh.isEmpty)
                    .opacity(fresh.isEmpty ? 0.5 : 1)
                    Text("If a server shows a connection error afterwards, its authorized_keys does not have this iPhone's key yet: show your code (Settings → This iPhone's SSH key) to the other iPhone again.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("Servers from another iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationBackground(Theme.bg)
    }
}

/// Settings card: this iPhone's key as a QR code for an iPhone that already has the servers.
struct PhoneKeyCard: View {
    @State private var copied: String?
    private var link: String { PhoneLink.authorizeLink(key: AppIdentity.publicKeyLine, name: UIDevice.current.name) }

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    QRCode(text: link)
                        .frame(width: 120, height: 120)
                        .padding(6)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("This iPhone's key as a QR code")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Already monitoring from another iPhone?").font(.system(size: 14, weight: .semibold))
                        Text("Scan this with that iPhone's camera. It puts this key on its servers and sends the server list back here.")
                            .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    }
                }
                Text(AppIdentity.fingerprint).font(Theme.mono(11)).foregroundStyle(Theme.text2).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Text("Added to authorized_keys when you set up a server with a password. For a server you prepare yourself, the setup script adds it.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                HStack(spacing: 8) {
                    button("Copy public key", AppIdentity.publicKeyLine)
                    ShareLink(item: link, subject: Text("Server Monitor key"), message: Text("Open in Server Monitor to authorize this iPhone: ")) {
                        Label("Share link", systemImage: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func button(_ title: String, _ value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copied = title
        } label: {
            Label(copied == title ? "Copied" : title, systemImage: copied == title ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        }
        .buttonStyle(.plain)
    }
}

/// Settings section: the iPhones this phone has authorized, with revoke, plus pasting a key by hand.
struct AuthorizedPhonesSection: View {
    @Environment(ServerStore.self) private var store
    @State private var pasted = ""
    @State private var pasteError: String?
    @State private var revoking: AuthorizedPhone?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 8) {
            SectionHeader(text: "Other iPhones")
            ListCard {
                ForEach(store.authorizedPhones) { p in
                    HStack(spacing: 12) {
                        Image(systemName: "iphone.gen3").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.system(size: 15, weight: .medium))
                            Text("\(p.serverIDs.filter { id in store.servers.contains { $0.id == id } }.count) servers · \(p.fingerprint)")
                                .font(Theme.mono(11)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Revoke") { revoking = p }
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.crit)
                            .disabled(busy)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
                HStack(spacing: 8) {
                    TextField("Paste another iPhone's key (ssh-ed25519 …)", text: $pasted)
                        .font(Theme.mono(12))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Authorize") {
                        if let k = PhoneLink.validKey(pasted) {
                            store.pendingAuthorize = PhoneLink.Authorize(key: k, name: "iPhone")
                            pasted = ""
                            pasteError = nil
                        } else {
                            pasteError = "That is not an ed25519 public key line."
                        }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .disabled(pasted.isEmpty)
                }
                .padding(.horizontal, 14).frame(minHeight: 48)
            }
            Text(pasteError ?? "Easiest: scan the other iPhone's code (its Settings → This iPhone's SSH key) with the Camera app. Revoke removes its key from every server it was put on.")
                .font(.system(size: 12)).foregroundStyle(pasteError == nil ? Theme.text2 : Theme.crit)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
        }
        .confirmationDialog("Revoke \(revoking?.name ?? "")?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            Button("Remove its key from the servers", role: .destructive) {
                if let p = revoking { Task { await revoke(p) } }
            }
            Button("Cancel", role: .cancel) { revoking = nil }
        } message: {
            Text("That iPhone can no longer log in to \(revoking.map { String($0.serverIDs.count) } ?? "its") servers. Its own app keeps the entries until they are removed there.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        }
    }

    private func revoke(_ p: AuthorizedPhone) async {
        busy = true
        let targets = store.servers.filter { p.serverIDs.contains($0.id) }
        let fails = await store.revoke(key: p.key, on: targets)
        if fails.isEmpty {
            store.authorizedPhones.removeAll { $0.id == p.id }
            message = "Key removed from \(targets.count) server\(targets.count == 1 ? "" : "s")."
        } else {
            // keep only the servers that still have the key, so Revoke can be tried again
            if let i = store.authorizedPhones.firstIndex(where: { $0.id == p.id }) {
                store.authorizedPhones[i].serverIDs = targets.filter { fails[$0.id] != nil }.map(\.id)
            }
            message = "Could not remove the key on: " + targets.filter { fails[$0.id] != nil }.map { "\($0.name) (\(fails[$0.id] ?? ""))" }.joined(separator: ", ")
        }
        store.savePhones()
        busy = false
        revoking = nil
    }
}
