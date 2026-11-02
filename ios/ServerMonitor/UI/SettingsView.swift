import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(ServerStore.self) private var store
    @State private var keyID = PushSettings.keyID
    @State private var teamID = PushSettings.teamID
    @State private var p8Loaded = PushSettings.keyP8 != nil
    @State private var importP8 = false
    @State private var deploying = false
    @State private var message: String?
    @AppStorage("applock.enabled") private var appLock = true

    private var canDeploy: Bool { p8Loaded && keyID.count == 10 && teamID.count == 10 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Settings").font(.system(size: 34, weight: .bold)).tracking(-0.6).padding(.top, 8)

                    if store.isAdmin {
                    VStack(spacing: 8) {
                        SectionHeader(text: "Push notifications (APNs)")
                        ListCard {
                            HStack(spacing: 12) {
                                Image(systemName: "key.horizontal").foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p8Loaded ? "APNs key loaded" : "No APNs key").font(.system(size: 15, weight: .medium))
                                    Text(".p8 from Apple Developer › Keys").font(.system(size: 12)).foregroundStyle(Theme.text2)
                                }
                                Spacer()
                                Button(p8Loaded ? "Replace" : "Import") { importP8 = true }
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .padding(14)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                            idField("Key ID", $keyID)
                            idField("Team ID", $teamID)
                            HStack {
                                Text("Bundle ID").font(.system(size: 15))
                                Spacer()
                                Text(PushSettings.bundleID).font(Theme.mono(13)).foregroundStyle(Theme.text2)
                            }
                            .padding(.horizontal, 14).frame(minHeight: 48)
                        }
                        Button {
                            Task { await deploy() }
                        } label: {
                            HStack {
                                if deploying { ProgressView().controlSize(.small) }
                                Text("Save & deploy to \(store.servers.filter(\.installed).count) servers")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!canDeploy || deploying)
                        .opacity(canDeploy ? 1 : 0.5)
                        Text("One key serves every server. To rotate it, revoke the old key in Apple Developer, import the new one here and deploy.")
                            .font(.system(size: 12)).foregroundStyle(Theme.text2).padding(.horizontal, 4)
                    }

                    VStack(spacing: 8) {
                        SectionHeader(text: "This iPhone's SSH key")
                        PhoneKeyCard()
                    }

                    AuthorizedPhonesSection()
                    }

                    TeamMembershipSection()

                    VStack(spacing: 8) {
                        SectionHeader(text: "Security")
                        ListCard {
                            Toggle(isOn: $appLock) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Lock with Face ID").font(.system(size: 15))
                                    Text("Asked when the app opens").font(.system(size: 12)).foregroundStyle(Theme.text2)
                                }
                            }
                            .tint(Theme.ok)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                    }

                    AppInfoSection(pushEnv: store.pushEnv, deviceToken: store.deviceToken)
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .fileImporter(isPresented: $importP8, allowedContentTypes: [.data, .text, .item]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let s = try? String(contentsOf: url, encoding: .utf8), s.contains("BEGIN PRIVATE KEY") else {
                    message = "That file is not an APNs .p8 key."
                    return
                }
                PushSettings.keyP8 = s
                p8Loaded = true
                // Apple names the file AuthKey_<KEYID>.p8
                let name = url.deletingPathExtension().lastPathComponent
                if name.hasPrefix("AuthKey_") { keyID = String(name.dropFirst(8)) }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            }
        }
    }

    private func idField(_ label: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 15)).frame(width: 80, alignment: .leading)
            TextField("10 characters", text: text)
                .font(Theme.mono(15))
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .onChange(of: text.wrappedValue) { _, v in
                    let f = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(10))
                    if f != v { text.wrappedValue = f }
                }
                .accessibilityLabel(label)
        }
        .padding(.horizontal, 14).frame(minHeight: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 14))
            Spacer()
            Text(v).font(Theme.mono(12)).foregroundStyle(Theme.text2)
        }
    }

    private func deploy() async {
        PushSettings.keyID = keyID
        PushSettings.teamID = teamID
        deploying = true
        let failures = await store.deployPushEverywhere()
        deploying = false
        if failures.isEmpty {
            message = store.deviceToken == nil
                ? "Key deployed. This iPhone has no push token yet — allow notifications and reopen the app."
                : "Key deployed and this iPhone registered on all servers."
        } else {
            message = "Failed on: " + failures.map { "\($0.key) (\($0.value))" }.sorted().joined(separator: ", ")
        }
    }
}

/// Member: who I am on the team. Anyone: join with a pasted invite link.
struct TeamMembershipSection: View {
    @Environment(ServerStore.self) private var store
    @State private var link = ""
    @State private var confirmLeave = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 8) {
            SectionHeader(text: "Team")
            if let m = store.member {
                ListCard {
                    row("Signed in as", m.name)
                    row("Role", m.roleLabel)
                    row("Relay", URL(string: m.relayURL)?.host ?? m.relayURL)
                    Button(role: .destructive) { confirmLeave = true } label: {
                        Text("Leave team").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.crit)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
                .confirmationDialog("Leave the team?", isPresented: $confirmLeave, titleVisibility: .visible) {
                    Button("Leave", role: .destructive) { store.leaveTeam() }
                } message: { Text("You need a new invite to get access again.") }
            } else {
                ListCard {
                    HStack(spacing: 8) {
                        TextField("Paste invite link (srvmon://join…)", text: $link)
                            .font(Theme.mono(13))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Join") {
                            if let l = TeamJoin.parse(link) { store.pendingJoin = l; link = "" } else { error = "That is not an invite link." }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .disabled(link.isEmpty)
                    }
                    .padding(.horizontal, 14).frame(minHeight: 48)
                }
                Text(error ?? "Got an invite from an admin? Scan its QR code with the Camera app, or paste the link here.")
                    .font(.system(size: 12)).foregroundStyle(error == nil ? Theme.text2 : Theme.crit)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 15))
            Spacer()
            Text(v).font(.system(size: 14)).foregroundStyle(Theme.text2)
        }
        .padding(.horizontal, 14).frame(minHeight: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// App info with the appinsource label.
struct AppInfoSection: View {
    let pushEnv: String
    let deviceToken: String?
    @Environment(\.openURL) private var openURL

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "Version \(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 8) {
            SectionHeader(text: "App info")
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        AppMark().frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Server Monitor").font(.system(size: 17, weight: .semibold))
                            Text(version).font(Theme.mono(12)).foregroundStyle(Theme.text2)
                        }
                    }
                    Rectangle().fill(Theme.border).frame(height: 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DESIGNED & DEVELOPED BY").font(.system(size: 11)).tracking(0.9).foregroundStyle(Theme.text2)
                        BrandWordmark(size: 20)
                        Text("Süleyman Topaloğlu").font(.system(size: 13)).foregroundStyle(Color(hex: 0xC9CED6))
                    }
                    HStack(spacing: 8) {
                        linkButton("appinsource.eu", "globe", "https://appinsource.eu")
                        linkButton("Contact", "envelope", "mailto:developer@appinsource.eu")
                    }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Push environment: \(pushEnv)")
                            Text("Device token: \(deviceToken.map { String($0.prefix(12)) + "…" } ?? "not registered")")
                        }
                        .font(Theme.mono(11)).foregroundStyle(Theme.text2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    } label: {
                        Text("Diagnostics").font(.system(size: 13)).foregroundStyle(Theme.text2)
                    }
                    .tint(Theme.text2)
                }
            }
            Text("© 2026 appinsource · Made in Germany")
                .font(.system(size: 11)).foregroundStyle(Theme.text3).padding(.top, 4)
        }
    }

    private func linkButton(_ title: String, _ icon: String, _ url: String) -> some View {
        Button { if let u = URL(string: url) { openURL(u) } } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        }
        .buttonStyle(.plain)
    }
}

/// The app icon drawn in SwiftUI: three server bars with status dots.
struct AppMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14).fill(Theme.surface2)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
            .overlay {
                VStack(spacing: 5) {
                    ForEach([Theme.ok, Theme.warn, Theme.accent], id: \.self) { c in
                        RoundedRectangle(cornerRadius: 3).fill(Theme.border).frame(height: 10)
                            .overlay(alignment: .leading) { Circle().fill(c).frame(width: 5, height: 5).padding(.leading, 4) }
                    }
                }
                .padding(.horizontal, 10)
            }
            .accessibilityHidden(true)
    }
}
