import SwiftUI
import UIKit
import SwiftTerm
import Citadel
import NIOCore
import NIOSSH

/// One interactive shell (PTY) over the server's SSH connection.
final class TerminalSession: NSObject, ObservableObject, TerminalViewDelegate {
    enum State: Equatable {
        case connecting
        case connected
        case closed(String)
    }

    @Published var state: State = .connecting
    weak var view: SwiftTerm.TerminalView?

    private let session: SSHSession
    private var task: Task<Void, Never>?
    // keystrokes go through one ordered stream so they never overtake each other
    private var input: AsyncStream<[UInt8]>.Continuation?
    private var resize: AsyncStream<(Int, Int)>.Continuation?

    init(session: SSHSession) {
        self.session = session
    }

    func start() {
        task?.cancel()
        state = .connecting
        let (inStream, inCont) = AsyncStream<[UInt8]>.makeStream()
        let (sizeStream, sizeCont) = AsyncStream<(Int, Int)>.makeStream(bufferingPolicy: .bufferingNewest(1))
        input = inCont
        resize = sizeCont
        let term = view?.getTerminal()
        let cols = max(term?.cols ?? 80, 20), rows = max(term?.rows ?? 24, 5)

        task = Task { [weak self, session] in
            do {
                let client = try await session.connect()
                let req = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true, term: "xterm-256color",
                    terminalCharacterWidth: cols, terminalRowHeight: rows,
                    terminalPixelWidth: 0, terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([:]))
                try await client.withPTY(req) { inbound, outbound in
                    await MainActor.run { self?.state = .connected }
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await chunk in inbound {
                                let buf: ByteBuffer
                                switch chunk {
                                case .stdout(let b): buf = b
                                case .stderr(let b): buf = b
                                }
                                let bytes = Array(buf.readableBytesView)
                                await MainActor.run { self?.view?.feed(byteArray: bytes[...]) }
                            }
                        }
                        group.addTask {
                            for await bytes in inStream {
                                try await outbound.write(ByteBuffer(bytes: bytes))
                            }
                        }
                        group.addTask {
                            for await (c, r) in sizeStream {
                                try? await outbound.changeSize(cols: c, rows: r, pixelWidth: 0, pixelHeight: 0)
                            }
                        }
                        // the shell ended (exit / logout): stop the writers too
                        try await group.next()
                        group.cancelAll()
                    }
                }
                await MainActor.run { self?.finish("Session ended") }
            } catch is CancellationError {
                await MainActor.run { self?.finish("Disconnected") }
            } catch {
                await MainActor.run { self?.finish(friendlyError(error)) }
            }
        }
    }

    private func finish(_ message: String) {
        input?.finish()
        resize?.finish()
        input = nil
        resize = nil
        state = .closed(message)
    }

    func stop() {
        task?.cancel()
        task = nil
        input?.finish()
        resize?.finish()
    }

    /// Sends text as if typed (used by the quick-command buttons).
    func type(_ s: String) {
        input?.yield(Array(s.utf8))
    }

    // MARK: TerminalViewDelegate

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        input?.yield(Array(data))
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        resize?.yield((newCols, newRows))
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        if let u = URL(string: link), u.scheme == "https" || u.scheme == "http" { UIApplication.shared.open(u) }
    }

    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
    }
}

struct TerminalHost: UIViewRepresentable {
    let session: TerminalSession

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let v = SwiftTerm.TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        v.terminalDelegate = session
        v.nativeBackgroundColor = UIColor(Theme.logBg)
        v.nativeForegroundColor = UIColor(Theme.text)
        v.caretColor = UIColor(Theme.accent)
        v.optionAsMetaKey = true
        session.view = v
        DispatchQueue.main.async {
            session.start()
            _ = v.becomeFirstResponder()
        }
        return v
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {}

    static func dismantleUIView(_ uiView: SwiftTerm.TerminalView, coordinator: ()) {
        (uiView.terminalDelegate as? TerminalSession)?.stop()
    }
}

struct TerminalScreen: View {
    @Environment(ServerStore.self) private var store
    let server: ServerRecord
    @StateObject private var session: TerminalSession

    init(server: ServerRecord, sshSession: SSHSession) {
        self.server = server
        _session = StateObject(wrappedValue: TerminalSession(session: sshSession))
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            TerminalHost(session: session)
                .background(Theme.logBg)
            quickKeys
        }
        .background(Theme.logBg)
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            switch session.state {
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("Connecting…")
            case .connected:
                Circle().fill(Theme.ok).frame(width: 7, height: 7)
                Text("\(server.username)@\(server.host)")
                    .font(Theme.mono(11))
                if server.username == "root" {
                    Text("root shell").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.warn)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.warn.opacity(0.15), in: Capsule())
                }
            case .closed(let msg):
                Circle().fill(Theme.crit).frame(width: 7, height: 7)
                Text(msg).lineLimit(1)
                Spacer()
                Button {
                    session.start()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.text2)
        .padding(.horizontal, 12).frame(height: 30)
        .background(Theme.surface)
    }

    private var quickKeys: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(QuickCommand.all) { q in
                    Button(q.label) { session.type(q.text) }
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 10).frame(minHeight: 34)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                        .disabled(session.state != .connected)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(Theme.surface)
    }
}

struct QuickCommand: Identifiable {
    let label: String
    let text: String
    var id: String { label }

    static let all: [QuickCommand] = [
        .init(label: "docker ps", text: "docker ps --format 'table {{.Names}}\\t{{.Status}}'\n"),
        .init(label: "df -h", text: "df -h /\n"),
        .init(label: "free -h", text: "free -h\n"),
        .init(label: "htop", text: "htop || top\n"),
        .init(label: "logs -f", text: "journalctl -f -n 50\n"),
        .init(label: "Ctrl-C", text: "\u{03}"),
        .init(label: "clear", text: "clear\n"),
        .init(label: "exit", text: "exit\n"),
    ]
}
