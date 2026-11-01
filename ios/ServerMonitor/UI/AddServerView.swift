import SwiftUI
import UniformTypeIdentifiers

struct AddServerView: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var input: NewServerInput
    @State private var portText: String
    @State private var installer: Installer?
    @State private var importKey = false
    @State private var confirmDelete = false
    /// A saved, unfinished setup being continued.
    let draft: ServerRecord?

    init(draft: ServerRecord? = nil) {
        self.draft = draft
        let i = draft.map { NewServerInput(draft: $0) } ?? NewServerInput()
        _input = State(initialValue: i)
        _portText = State(initialValue: String(i.port))
    }

    enum AuthChoice: Hashable { case password, iphone, file }

    private var authChoice: Binding<AuthChoice> {
        Binding(get: { input.usesAppKey ? .iphone : input.useKey ? .file : .password },
                set: { c in
                    input.draftAuth = c == .iphone ? .appKey : nil
                    input.useKey = c == .file
                })
    }

    private var valid: Bool {
        !input.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !input.host.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Int(portText) ?? 0) > 0 &&
        (input.usesAppKey || (input.useKey ? input.privateKeyPEM.contains("PRIVATE KEY") : !input.password.isEmpty)) &&
        !store.servers.contains { $0.name == input.name.trimmingCharacters(in: .whitespaces) && $0.id != draft?.id }
    }

    var body: some View {
        NavigationStack {
            if let installer {
                InstallProgressView(installer: installer, title: "Setting up \(input.name)") { dismiss() }
            } else {
                form
            }
        }
        .presentationBackground(Theme.bg)
    }

    private var form: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    SectionHeader(text: "Connection")
                    ListCard {
                        field("Name", text: $input.name, placeholder: "web-02")
                        field("Host", text: $input.host, placeholder: "10.0.1.31 or host.example.com", mono: true, keyboard: .URL)
                        HStack(spacing: 0) {
                            field("Port", text: $portText, placeholder: "22", mono: true, keyboard: .numberPad, trailing: true)
                            Rectangle().fill(Theme.border).frame(width: 1, height: 48)
                            field("User", text: $input.username, placeholder: "root", mono: true, trailing: true)
                        }
                    }
                }

                VStack(spacing: 8) {
                    SectionHeader(text: "Authentication")
                    Segmented(options: [(AuthChoice.password, "Password"), (AuthChoice.iphone, "iPhone key"), (AuthChoice.file, "Key file")],
                              selection: authChoice)
                    if input.usesAppKey {
                        IPhoneKeyCard()
                    } else if input.useKey {
                        ListCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Private key (OpenSSH format)").font(.system(size: 13)).foregroundStyle(Theme.text2)
                                    Spacer()
                                    Button("Import file") { importKey = true }.font(.system(size: 13, weight: .medium))
                                }
                                TextEditor(text: $input.privateKeyPEM)
                                    .font(Theme.mono(11))
                                    .scrollContentBackground(.hidden)
                                    .frame(height: 110)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .accessibilityLabel("Private key")
                            }
                            .padding(14)
                            Rectangle().fill(Theme.border).frame(height: 1)
                            secureField("Passphrase", text: $input.passphrase, placeholder: "optional")
                        }
                    } else {
                        ListCard {
                            secureField("Password", text: $input.password, placeholder: "root password")
                            Rectangle().fill(Theme.border).frame(height: 1)
                            toggle("Use app key afterwards", "Adds this iPhone's SSH key; password is not stored", $input.switchToAppKey)
                        }
                    }
                }

                VStack(spacing: 8) {
                    SectionHeader(text: "Setup")
                    ListCard {
                        toggle("Push alerts", PushSettings.configured ? "Uses your saved APNs key" : "Add the APNs key in Settings first", $input.pushAlerts)
                        Rectangle().fill(Theme.border).frame(height: 1)
                        toggle("Watch other servers", "Reports a server that stops answering", $input.watchOthers)
                        Rectangle().fill(Theme.border).frame(height: 1)
                        toggle("Container actions", "Allow start / stop / restart from the app", $input.allowActions)
                    }
                }

                Text("Credentials stay in this iPhone's Keychain. The agent listens on a local socket only; the app reads it through SSH, so no port is opened on the server.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                Button("Connect & install agent") { start() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!valid)
                    .opacity(valid ? 1 : 0.5)

                if draft != nil {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text("Delete this server").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.crit)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(Theme.bg)
        .navigationTitle(draft == nil ? "Add server" : "Continue setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(draft == nil ? "Cancel" : "Close") { dismiss() } }
        }
        .confirmationDialog("Delete \(input.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let d = draft { Task { await store.remove(d, uninstall: false); dismiss() } }
            }
        } message: { Text("The saved connection and its password are removed from this iPhone.") }
        .fileImporter(isPresented: $importKey, allowedContentTypes: [.data, .text, .item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let s = try? String(contentsOf: url, encoding: .utf8) { input.privateKeyPEM = s }
        }
    }

    private func start() {
        input.port = Int(portText) ?? 22
        let inst = Installer(input: input, store: store)
        installer = inst
        Task { await inst.run() }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, mono: Bool = false,
                       keyboard: UIKeyboardType = .default, trailing: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 15)).frame(width: trailing ? nil : 70, alignment: .leading)
            TextField(placeholder, text: text)
                .font(mono ? Theme.mono(15) : .system(size: 15))
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .multilineTextAlignment(trailing ? .trailing : .leading)
                .accessibilityLabel(label)
        }
        .padding(.horizontal, 14).frame(minHeight: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func secureField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 15)).frame(width: 90, alignment: .leading)
            SecureField(placeholder, text: text).font(.system(size: 15)).accessibilityLabel(label)
        }
        .padding(.horizontal, 14).frame(minHeight: 48)
    }

    private func toggle(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
        }
        .tint(Theme.ok)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct InstallProgressView: View {
    @Environment(\.dismiss) private var dismiss
    let installer: Installer
    let title: String
    var onDone: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                HStack {
                    Text(installer.server.map { "\($0.username)@\($0.host)" } ?? "").foregroundStyle(Theme.text2)
                    Spacer()
                    Text(stepText).font(Theme.mono(13))
                }
                .font(.system(size: 13))
                ProgressView(value: installer.progress).tint(installer.failedMessage == nil ? Theme.accent : Theme.crit)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card(padding: 14) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(installer.steps) { s in
                                HStack(alignment: .top, spacing: 12) {
                                    icon(s.state).frame(width: 24, height: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.title).font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(s.state == .pending ? Theme.text3 : Theme.text)
                                        Text(s.detail).font(Theme.mono(12))
                                            .foregroundStyle(s.state == .failed ? Theme.crit : Theme.text2)
                                    }
                                }
                                .padding(.vertical, 10)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    if !installer.log.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(installer.log.suffix(8).enumerated()), id: \.offset) { _, l in
                                Text(l).font(Theme.mono(11)).foregroundStyle(Color(hex: 0xC9CED6))
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.logBg, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
                    }
                }
            }

            if installer.finished {
                Button("Done") { onDone?() ?? dismiss() }.buttonStyle(PrimaryButtonStyle())
            } else if let failure = installer.failedMessage {
                Banner(icon: "exclamationmark.triangle.fill", title: "Setup stopped", text: failure, color: Theme.crit)
                HStack(spacing: 10) {
                    Button("Close") { onDone?() ?? dismiss() }.buttonStyle(PrimaryButtonStyle(secondary: true))
                    Button {
                        Task { await installer.retry() }
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            } else {
                Button("Continue in background") { onDone?() ?? dismiss() }.buttonStyle(PrimaryButtonStyle(secondary: true))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Theme.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(!installer.finished && installer.failedMessage == nil)
    }

    private var stepText: String {
        let i = (installer.steps.firstIndex { $0.state == .running || $0.state == .failed } ?? installer.steps.count - 1) + 1
        return installer.finished ? "Done" : "Step \(i) of \(installer.steps.count)"
    }

    @ViewBuilder
    private func icon(_ s: Installer.StepState) -> some View {
        switch s {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).font(.system(size: 22))
        case .running: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.crit).font(.system(size: 22))
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(Theme.text3).font(.system(size: 22))
        case .pending: Circle().stroke(Color(hex: 0x3A404A), lineWidth: 2).frame(width: 20, height: 20)
        }
    }
}

/// Shows this iPhone's public key and the one-line command to authorize it on a server.
struct IPhoneKeyCard: View {
    @State private var copied: String?
    private var command: String {
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(AppIdentity.publicKeyLine)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }
    var body: some View {
        ListCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Use this when the server doesn't accept a root password. Run this once on the server (for example from your Mac's SSH session), then connect:")
                    .font(.system(size: 13)).foregroundStyle(Theme.text2)
                Text(command)
                    .font(Theme.mono(11)).foregroundStyle(Theme.text)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.logBg, in: RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    copyButton("Copy command", command)
                    copyButton("Copy key only", AppIdentity.publicKeyLine)
                }
                Text(AppIdentity.fingerprint).font(Theme.mono(10)).foregroundStyle(Theme.text3)
            }
            .padding(14)
        }
    }

    private func copyButton(_ title: String, _ value: String) -> some View {
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
