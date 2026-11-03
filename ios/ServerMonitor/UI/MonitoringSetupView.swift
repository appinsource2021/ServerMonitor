import SwiftUI

/// The script a server's admin runs once, as root, to let this iPhone monitor the
/// server without root: a locked-down user with key-only login, and the agent with
/// `socket_group` so that user may call it. The same script updates the agent later.
enum MonitoringSetupScript {
    static func make(user: String, serverName: String, key: String, sha: String) -> String {
        let u = user.trimmingCharacters(in: .whitespaces)
        let name = serverName.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "'", with: "")
        return #"""
        #!/bin/sh
        # Server Monitor (appinsource): monitoring user "\#(u)" + srvmon-agent. Run as root.
        # Before running: copy the agent binary to /tmp/srvmon-agent (the app shares it).
        # Safe to run again for updates: user, key and config are kept.
        set -eu
        U='\#(u)'
        IPHONE_KEY='\#(k)'
        SHA=\#(sha)
        NAME='\#(name.isEmpty ? "Server" : name)'

        echo "== 1. user and group"
        getent group "$U" >/dev/null || groupadd --system "$U"
        id "$U" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --gid "$U" "$U"
        passwd -l "$U" >/dev/null
        H=$(getent passwd "$U" | cut -d: -f6)
        install -d -m 700 -o "$U" -g "$U" "$H/.ssh"
        [ -f "$H/.ssh/authorized_keys" ] || install -m 600 -o "$U" -g "$U" /dev/null "$H/.ssh/authorized_keys"
        grep -qF "$IPHONE_KEY" "$H/.ssh/authorized_keys" || printf '%s\n' "$IPHONE_KEY" >> "$H/.ssh/authorized_keys"

        echo "== 2. sshd: $U logs in with a key only, no forwarding"
        cat > "/etc/ssh/sshd_config.d/40-$U.conf" <<EOF
        Match User $U
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            AllowTcpForwarding no
            AllowAgentForwarding no
            AllowStreamLocalForwarding no
            X11Forwarding no
            PermitTunnel no
        EOF
        sshd -t && (systemctl reload ssh 2>/dev/null || systemctl reload sshd)

        echo "== 3. agent"
        SRC=''
        for f in /tmp/srvmon-agent "$H/srvmon-agent"; do [ -f "$f" ] && SRC="$f" && break; done
        if [ -n "$SRC" ]; then
          echo "$SHA  $SRC" | sha256sum -c -
          [ -x /usr/local/bin/srvmon-agent ] && cp -p /usr/local/bin/srvmon-agent /usr/local/bin/srvmon-agent.prev || true
          install -m 755 "$SRC" /usr/local/bin/srvmon-agent.new
          mv -f /usr/local/bin/srvmon-agent.new /usr/local/bin/srvmon-agent
          rm -f "$SRC"
        elif [ -x /usr/local/bin/srvmon-agent ]; then
          echo "no new file in /tmp/srvmon-agent or $H/srvmon-agent; keeping the installed agent $(/usr/local/bin/srvmon-agent version)"
        else
          echo "ERROR: no agent file. Use 'Send to server' in the app, or copy it to /tmp/srvmon-agent." >&2; exit 1
        fi
        install -d -m 700 /etc/srvmon
        if [ ! -f /etc/srvmon/config.json ]; then
          cat > /etc/srvmon/config.json <<EOF
        {
          "name": "$NAME",
          "socket": "/run/srvmon/agent.sock",
          "socket_group": "$U",
          "allow_actions": true
        }
        EOF
          chmod 600 /etc/srvmon/config.json
        fi
        cat > /etc/systemd/system/srvmon-agent.service <<'EOF'
        [Unit]
        Description=srvmon agent (server monitor for iOS)
        After=network-online.target docker.service
        Wants=network-online.target

        [Service]
        ExecStart=/usr/local/bin/srvmon-agent run -config /etc/srvmon/config.json
        Restart=always
        RestartSec=5
        RuntimeDirectory=srvmon
        RuntimeDirectoryMode=0750
        NoNewPrivileges=true
        ProtectSystem=full
        PrivateTmp=true
        ReadWritePaths=/etc/srvmon

        [Install]
        WantedBy=multi-user.target
        EOF
        systemctl daemon-reload
        systemctl enable srvmon-agent >/dev/null 2>&1
        systemctl restart srvmon-agent
        sleep 1

        echo "== 4. check"
        /usr/local/bin/srvmon-agent version
        sudo -u "$U" /usr/local/bin/srvmon-agent api GET /v1/health | head -n1
        ls -la /run/srvmon/
        id "$U"
        echo "OK"
        """#
    }
}

/// Shown from Add server when the User is not root: everything the server's admin needs,
/// generated on the phone with this iPhone's key already in place.
struct MonitoringSetupView: View {
    enum Mode { case setup, update }

    @Environment(\.dismiss) private var dismiss
    @Environment(ServerStore.self) private var store
    let username: String
    let host: String
    let serverName: String
    var mode: Mode = .setup
    /// A connected server: the sheet can then send the file over itself (SFTP as the login user).
    var server: ServerRecord? = nil

    @State private var arch = "amd64"
    @State private var copied: String?
    @State private var sending = false
    @State private var sendProgress = 0.0
    @State private var sentTo: String?
    @State private var sendError: String?

    private var user: String { username.trimmingCharacters(in: .whitespaces) }
    private var sha: String { BundledAgent.sha256(arch: arch) ?? "" }
    private var script: String {
        MonitoringSetupScript.make(user: user, serverName: serverName, key: AppIdentity.publicKeyLine, sha: sha)
    }
    private var scpCommand: String {
        "scp srvmon-agent-linux-\(arch) root@\(host.trimmingCharacters(in: .whitespaces).isEmpty ? "SERVER" : host.trimmingCharacters(in: .whitespaces)):/tmp/srvmon-agent"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(mode == .update
                         ? "The app is not root on this server and its agent cannot replace itself yet. Do this once, as root: copy the new agent over and run the script. From agent 0.3.6 on, Update now does it from here."
                         : "The server's admin does this once, as root. Afterwards this iPhone logs in as \(user), which can only talk to the agent. Root login stays as it is.")
                        .font(.system(size: 13)).foregroundStyle(Theme.text2)

                    step(1, "Send the agent to the server") {
                        if let server, mode == .update {
                            Text("The app can put the file there itself, as \(user), through the agent's upload folder. The script then picks it up from /home/\(user)/srvmon-agent.")
                                .font(.system(size: 13)).foregroundStyle(Theme.text2)
                            if let arch = server.arch { Text("Architecture: \(arch)").font(.system(size: 12)).foregroundStyle(Theme.text3) }
                            Button {
                                Task { await send(server) }
                            } label: {
                                HStack(spacing: 8) {
                                    if sending { ProgressView().controlSize(.small).tint(Theme.bg) }
                                    Text(sending ? "Sending… \(Int(sendProgress * 100))%" : sentTo == nil ? "Send to server" : "Send again")
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(sending)
                            if let sentTo {
                                Label("On the server: \(sentTo)", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ok)
                            }
                            if let sendError {
                                Text(sendError).font(.system(size: 12)).foregroundStyle(Theme.crit)
                            }
                            Text("Or by hand: share the file and copy it to the server as /tmp/srvmon-agent.")
                                .font(.system(size: 12)).foregroundStyle(Theme.text3)
                        } else {
                            Text("Share the agent binary (AirDrop to a Mac, or save it to Files), then copy it to the server as /tmp/srvmon-agent:")
                                .font(.system(size: 13)).foregroundStyle(Theme.text2)
                        }
                        Segmented(options: [("amd64", "Intel / AMD (amd64)"), ("arm64", "ARM (arm64)")], selection: $arch)
                        code(scpCommand)
                        HStack(spacing: 8) {
                            if let url = BundledAgent.binaryURL(arch: arch) {
                                ShareLink(item: url, preview: SharePreview("srvmon-agent-linux-\(arch)")) {
                                    shareLabel("Share binary", "square.and.arrow.up")
                                }
                                .buttonStyle(.plain)
                            }
                            copyButton("Copy scp command", scpCommand)
                        }
                        Text("sha256 \(sha)").font(Theme.mono(10)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                    }

                    step(2, mode == .update ? "Run the script as root" : "Run the setup script as root") {
                        Text(mode == .update
                             ? "The same setup script: it keeps the \(user) user, the keys and the config, verifies the new file's sha256, swaps the agent in (old one kept as .prev) and restarts it. Ends with OK."
                             : "Creates the \(user) user (key-only login, no sudo), adds this iPhone's key and installs agent \(BundledAgent.version) with socket_group. Running it again later updates the agent.")
                            .font(.system(size: 13)).foregroundStyle(Theme.text2)
                        HStack(spacing: 8) {
                            copyButton("Copy script", script)
                            ShareLink(item: scriptFile(), preview: SharePreview("srvmon-setup.sh")) {
                                shareLabel("Share script", "square.and.arrow.up")
                            }
                            .buttonStyle(.plain)
                        }
                        ScrollView(.horizontal) {
                            Text(script).font(Theme.mono(10)).foregroundStyle(Theme.text).textSelection(.enabled)
                                .padding(10)
                        }
                        .frame(maxHeight: 260)
                        .background(Theme.logBg, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                    }

                    step(3, mode == .update ? "Check" : "Connect") {
                        Text(mode == .update
                             ? "Open the server in the app: the yellow strip disappears within a few seconds once \(BundledAgent.version) answers."
                             : "When the script ends with OK, come back and tap Connect to existing agent.")
                            .font(.system(size: 13)).foregroundStyle(Theme.text2)
                    }

                    Text("Whoever holds this iPhone's key can use the whole agent through the app, file edits included. The key never leaves this iPhone's Keychain.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .background(Theme.bg)
            .navigationTitle(mode == .update ? "Update agent on the server" : "Prepare \(user) on the server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { if let a = server?.arch, a == "amd64" || a == "arm64" { arch = a } }
        }
        .presentationBackground(Theme.bg)
    }

    /// Uploads the bundled binary into the agent's upload slot over SFTP and has the agent
    /// move it to /home/<user>/srvmon-agent (agent ≥ 0.3.3 for the slot, 0.3.5 for a non-root writer).
    private func send(_ server: ServerRecord) async {
        sending = true
        sendError = nil
        sendProgress = 0
        defer { sending = false }
        do {
            guard let url = BundledAgent.binaryURL(arch: arch) else { throw InstallError("No bundled agent for \(arch).") }
            let data = try Data(contentsOf: url)
            let api = store.api(for: server)
            struct Slot: Decodable { let temp: String }
            let slot = try JSON.decoder.decode(Slot.self, from: try await api.post("/v1/fs/upload"))
            try await store.session(for: server).upload(data, to: slot.temp) { p in
                Task { @MainActor in sendProgress = p }
            }
            struct Imp: Encodable { let temp: String; let path: String; let overwrite: Bool }
            let dest = "/home/\(user)/srvmon-agent"
            try await api.send("POST", "/v1/fs/import", Imp(temp: slot.temp, path: dest, overwrite: true))
            sentTo = dest
        } catch {
            sendError = friendlyError(error)
        }
    }

    private func step<C: View>(_ n: Int, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.bg)
                        .frame(width: 24, height: 24).background(Theme.accent, in: Circle())
                    Text(title).font(.system(size: 15, weight: .semibold))
                }
                content()
            }
        }
    }

    private func code(_ s: String) -> some View {
        Text(s).font(Theme.mono(11)).foregroundStyle(Theme.text)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.logBg, in: RoundedRectangle(cornerRadius: 10))
            .textSelection(.enabled)
    }

    private func shareLabel(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    private func copyButton(_ title: String, _ value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copied = title
        } label: {
            shareLabel(copied == title ? "Copied" : title, copied == title ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.plain)
    }

    /// The script as a file, for AirDrop or Files.
    private func scriptFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("srvmon-setup.sh")
        try? script.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
