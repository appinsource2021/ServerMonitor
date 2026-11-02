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
        [ -f /tmp/srvmon-agent ] || { echo "ERROR: /tmp/srvmon-agent missing. Copy the agent binary there first." >&2; exit 1; }
        echo "$SHA  /tmp/srvmon-agent" | sha256sum -c -
        install -m 755 /tmp/srvmon-agent /usr/local/bin/srvmon-agent.new
        mv -f /usr/local/bin/srvmon-agent.new /usr/local/bin/srvmon-agent
        rm -f /tmp/srvmon-agent
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
    @Environment(\.dismiss) private var dismiss
    let username: String
    let host: String
    let serverName: String

    @State private var arch = "amd64"
    @State private var copied: String?

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
                    Text("The server's admin does this once, as root. Afterwards this iPhone logs in as \(user), which can only talk to the agent. Root login stays as it is.")
                        .font(.system(size: 13)).foregroundStyle(Theme.text2)

                    step(1, "Send the agent to the server") {
                        Text("Share the agent binary (AirDrop to a Mac, or save it to Files), then copy it to the server as /tmp/srvmon-agent:")
                            .font(.system(size: 13)).foregroundStyle(Theme.text2)
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

                    step(2, "Run the setup script as root") {
                        Text("Creates the \(user) user (key-only login, no sudo), adds this iPhone's key and installs agent \(BundledAgent.version) with socket_group. Running it again later updates the agent.")
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

                    step(3, "Connect") {
                        Text("When the script ends with OK, come back and tap Connect to existing agent.")
                            .font(.system(size: 13)).foregroundStyle(Theme.text2)
                    }

                    Text("Whoever holds this iPhone's key can use the whole agent through the app, file edits included. The key never leaves this iPhone's Keychain.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .background(Theme.bg)
            .navigationTitle("Prepare \(user) on the server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationBackground(Theme.bg)
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
