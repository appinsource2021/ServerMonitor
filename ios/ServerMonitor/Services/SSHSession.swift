import Foundation
import CryptoKit
import Citadel
import NIOCore
import NIOSSH

enum SSHError: LocalizedError {
    case missingCredentials
    case hostKeyChanged(expected: String, got: String)
    case badPrivateKey(String)
    case commandFailed(code: Int, output: String)
    case loginRejected(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "No credentials stored for this server."
        case .loginRejected(let m): m
        case .hostKeyChanged: "The server's SSH host key changed. Connection refused for safety — remove and re-add the server if this is expected."
        case .badPrivateKey(let m): "Private key not usable: \(m)"
        case .commandFailed(let code, let out): "Command failed (\(code)): \(out.suffix(400))"
        }
    }
}

/// Trust-on-first-use: the first host key is saved, later connections must match.
final class HostKeyTOFU: NIOSSHClientServerAuthenticationDelegate {
    private let serverID: UUID
    init(serverID: UUID) { self.serverID = serverID }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        let k = Credentials.hostKeyKey(serverID)
        if let saved = Keychain.string(k) {
            if saved == presented {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHError.hostKeyChanged(expected: saved, got: presented))
            }
        } else {
            Keychain.setString(presented, for: k)
            validationCompletePromise.succeed(())
        }
    }
}

/// One SSH connection per server, reused for every agent call.
actor SSHSession {
    let server: ServerRecord
    private var client: SSHClient?

    /// Used during setup before credentials are saved.
    private let overridePassword: String?

    init(server: ServerRecord, password: String? = nil) {
        self.server = server
        self.overridePassword = password
    }

    private func authMethod() throws -> SSHAuthenticationMethod {
        switch server.auth {
        case .password:
            guard let pw = overridePassword ?? Keychain.string(Credentials.passwordKey(server.id)) else { throw SSHError.missingCredentials }
            return .passwordBased(username: server.username, password: pw)
        case .appKey:
            return .ed25519(username: server.username, privateKey: AppIdentity.privateKey)
        case .importedKey:
            guard let pem = Keychain.string(Credentials.privateKeyKey(server.id)) else { throw SSHError.missingCredentials }
            let pass = Keychain.get(Credentials.passphraseKey(server.id))
            if pem.contains("BEGIN OPENSSH PRIVATE KEY") {
                if let k = try? Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: pass) {
                    return .ed25519(username: server.username, privateKey: k)
                }
                if let k = try? Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: pass) {
                    return .rsa(username: server.username, privateKey: k)
                }
            }
            throw SSHError.badPrivateKey("use an OpenSSH ed25519 or RSA key (BEGIN OPENSSH PRIVATE KEY)")
        case .relay:
            throw SSHError.missingCredentials
        }
    }

    private var connecting: Task<SSHClient, Error>?

    /// Concurrent callers share one in-flight connect (actors are re-entrant across awaits).
    func connect() async throws -> SSHClient {
        if let c = client, c.isConnected { return c }
        client = nil
        if let pending = connecting { return try await pending.value }
        let auth = try authMethod()
        let host = server.host, port = server.port, id = server.id
        let task = Task {
            try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: auth,
                hostKeyValidator: .custom(HostKeyTOFU(serverID: id)),
                reconnect: .never
            )
        }
        connecting = task
        defer { connecting = nil }
        let c: SSHClient
        do {
            c = try await task.value
        } catch {
            let d = String(describing: error).lowercased()
            if d.contains("allauthenticationoptionsfailed") || d.contains("userauth") || d.contains("authentication") {
                throw SSHError.loginRejected(Self.loginHint(server))
            }
            throw error
        }
        client = c
        return c
    }

    /// What a rejected login most likely means, by login method and user.
    static func loginHint(_ s: ServerRecord) -> String {
        let who = "\(s.username)@\(s.host)"
        switch s.auth {
        case .appKey where s.username == "root":
            return "\(who) did not accept this iPhone's key. Add it to /root/.ssh/authorized_keys (Settings › This iPhone's SSH key › Copy public key), or set the server up with a password once so the app adds it."
        case .appKey:
            return "\(who) did not accept this iPhone's key. On the server check that /home/\(s.username)/.ssh/authorized_keys holds this iPhone's key (the setup script adds it when its IPHONE_KEY line is filled in) and that sshd allows the user (AllowUsers / AllowGroups): journalctl -u ssh | grep \(s.username) says why. Avoid repeated tries: the server may block this phone for a while."
        case .importedKey:
            return "\(who) did not accept the imported key. Its public half must be in that user's authorized_keys, and the passphrase must be right."
        case .password:
            return "Login failed. Check the password, or root login with a password may be disabled on the server (PermitRootLogin / PasswordAuthentication)."
        case .relay:
            return "Login failed."
        }
    }

    /// Runs a shell snippet, merging stderr, and returns output + exit code
    /// (never throws for a non-zero exit, only for transport errors).
    /// A dead connection (phone slept, Wi-Fi changed) can leave a command waiting forever,
    /// so every call has a deadline; on timeout the connection is dropped and rebuilt next time.
    func run(_ script: String, timeout: Duration = .seconds(600)) async throws -> (output: String, code: Int) {
        let wrapped = "{ \(script)\n} 2>&1; printf '\\n__RC:%s' \"$?\""
        let raw: String
        do {
            raw = try await withDeadline(timeout) { try await self.execute(wrapped) }
        } catch is DeadlineExceeded {
            dropConnection()
            throw SSHTimeout(seconds: Int(timeout.components.seconds))
        }
        guard let r = raw.range(of: "\n__RC:", options: .backwards) else { return (raw, -1) }
        let code = Int(raw[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        return (String(raw[..<r.lowerBound]), code)
    }

    /// Writes a file over SFTP in 32 KB chunks.
    func upload(_ data: Data, to path: String, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let sftp = try await connect().openSFTP()
        let file = try await sftp.openFile(filePath: path, flags: [.write, .create, .truncate])
        let chunk = 32 * 1024
        var offset = 0
        do {
            while offset < data.count {
                let end = min(offset + chunk, data.count)
                try await file.write(ByteBuffer(bytes: [UInt8](data[offset..<end])), at: UInt64(offset))
                offset = end
                progress?(Double(offset) / Double(max(data.count, 1)))
            }
            try await file.close()
        } catch {
            try? await file.close()
            try? await sftp.close()
            throw error
        }
        try? await sftp.close()
    }

    private func execute(_ wrapped: String) async throws -> String {
        do {
            return String(buffer: try await connect().executeCommand(wrapped, mergeStreams: true))
        } catch {
            // one retry on a dropped connection
            client = nil
            return String(buffer: try await connect().executeCommand(wrapped, mergeStreams: true))
        }
    }

    /// Forgets the current connection; the next call opens a fresh one.
    func dropConnection() {
        if let c = client { Task { try? await c.close() } }
        client = nil
        connecting?.cancel()
        connecting = nil
    }

    func close() async {
        try? await client?.close()
        client = nil
    }
}

struct SSHTimeout: LocalizedError {
    let seconds: Int
    var errorDescription: String? { "The server did not answer within \(seconds) s. The connection was reset; try again." }
}

struct DeadlineExceeded: Error {}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// Returns the operation's result, or throws DeadlineExceeded when it takes longer than `limit`.
/// Unlike a task group it does not wait for a stuck operation to notice cancellation.
func withDeadline<T: Sendable>(_ limit: Duration, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = OnceFlag()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let work = Task {
            do {
                let v = try await op()
                if once.take() { cont.resume(returning: v) }
            } catch {
                if once.take() { cont.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: limit)
            if once.take() {
                work.cancel()
                cont.resume(throwing: DeadlineExceeded())
            }
        }
    }
}

/// Calls `srvmon-agent api` on the server over the SSH session.
struct AgentAPI {
    enum Transport {
        case ssh(SSHSession)                 // admin: runs `srvmon-agent api` over SSH
        case relay(RelayClient, serverID: String) // team member: signed call through the relay
    }
    let transport: Transport
    static let binary = "/usr/local/bin/srvmon-agent"

    init(session: SSHSession) { transport = .ssh(session) }
    init(relay: RelayClient, serverID: String) { transport = .relay(relay, serverID: serverID) }

    struct HTTPError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message.isEmpty ? "Agent error \(status)" : message }
    }

    struct AgentMissing: LocalizedError {
        let detail: String
        var errorDescription: String? { "Agent not reachable on the server. \(detail)" }
    }

    func raw(_ method: String, _ path: String, body: Data? = nil, timeout: Duration = .seconds(90)) async throws -> Data {
        switch transport {
        case .relay(let client, let serverID):
            return try await client.call(serverID: serverID, method: method, path: path, body: body)
        case .ssh(let session):
            return try await rawSSH(session, method, path, body: body, timeout: timeout)
        }
    }

    private func rawSSH(_ session: SSHSession, _ method: String, _ path: String, body: Data?, timeout: Duration) async throws -> Data {
        var cmd = "\(Self.binary) api \(method) \(shq(path))"
        if let body, let s = String(data: body, encoding: .utf8) { cmd += " \(shq(s))" }
        let (out, code) = try await session.run(cmd, timeout: timeout)
        guard code == 0 else { throw AgentMissing(detail: out.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let nl = out.firstIndex(of: "\n"), out.hasPrefix("HTTP ") else {
            throw AgentMissing(detail: String(out.prefix(200)))
        }
        let status = Int(out[out.index(out.startIndex, offsetBy: 5)..<nl]) ?? 0
        let bodyData = Data(out[out.index(after: nl)...].utf8)
        guard (200..<300).contains(status) else {
            let msg = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any])?["error"] as? String
            throw HTTPError(status: status, message: msg ?? "")
        }
        return bodyData
    }

    func get<T: Decodable>(_ path: String, as: T.Type = T.self, timeout: Duration = .seconds(90)) async throws -> T {
        try JSON.decoder.decode(T.self, from: try await raw("GET", path, timeout: timeout))
    }

    @discardableResult
    func send(_ method: String, _ path: String, _ body: some Encodable, timeout: Duration = .seconds(90)) async throws -> Data {
        try await raw(method, path, body: try JSON.encoder.encode(body), timeout: timeout)
    }

    @discardableResult
    func post(_ path: String) async throws -> Data { try await raw("POST", path) }
}

/// POSIX single-quote escaping.
func shq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Turns low-level network/SSH errors into something a person can act on.
func friendlyError(_ error: Error) -> String {
    if let st = error as? SFTPMessage.Status {
        // The server's SFTP answer, with its reason; "error 1" alone says nothing.
        let why: String
        switch st.errorCode {
        case .permissionDenied: why = "permission denied. The login user cannot write there (for a non-root user the agent's upload folder must be group-writable, agent ≥ 0.3.7 makes it so)."
        case .noSuchFile: why = "no such file or folder on the server."
        default: why = "\(st.errorCode)."
        }
        return "SFTP failed: " + why + (st.message.isEmpty ? "" : " (\(st.message))")
    }
    if error is SSHError || error is SSHTimeout || error is InstallError || error is AgentAPI.HTTPError || error is AgentAPI.AgentMissing || error is RelayError {
        return error.localizedDescription
    }
    let d = String(describing: error)
    let l = d.lowercased()
    if l.contains("connection reset") || l.contains("errno: 54") || l.contains("broken pipe") {
        return "The server closed the connection. After several failed logins it may have blocked this phone for a while (fail2ban). Wait a few minutes, and use “iPhone key” if password login is disabled."
    }
    if l.contains("errno: 1)") || l.contains("error 1") || l.contains("operation not permitted") {
        return "iOS blocked the connection before it left the phone. Check Settings › Mobile Data › Server Monitor, and any VPN, ad-blocker or DNS-filter app; then try again."
    }
    if l.contains("connection refused") || l.contains("errno: 61") {
        return "The server refused the connection: nothing listens on that SSH port. Check the port number."
    }
    if l.contains("timed out") || l.contains("timeout") || l.contains("errno: 60") {
        return "No answer from the server. A firewall may allow SSH only from certain IP addresses, or the address is wrong."
    }
    if l.contains("host is down") || l.contains("unreachable") || l.contains("errno: 51") || l.contains("errno: 65") {
        return "The server can't be reached from this network. Try Wi-Fi instead of mobile data, or the other way round."
    }
    if l.contains("authentication") || l.contains("allauthenticationoptionsfailed") || l.contains("userauth") {
        return "Login failed. Check the password, or root login with a password may be disabled on the server (PermitRootLogin / PasswordAuthentication)."
    }
    if l.contains("nodename nor servname") || l.contains("unknown host") || l.contains("getaddrinfo") {
        return "The host name could not be found. Check the address."
    }
    return error.localizedDescription == "The operation couldn’t be completed." ? d : error.localizedDescription
}
