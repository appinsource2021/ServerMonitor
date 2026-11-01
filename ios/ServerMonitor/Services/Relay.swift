import Foundation
import CryptoKit
import UIKit

// MARK: - Settings stored on this iPhone

/// Admin side: relay address + admin token (from the relay's first start).
enum RelaySettings {
    static var url: String {
        get { UserDefaults.standard.string(forKey: "relay.url") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: "relay.url") }
    }
    static var adminToken: String? {
        get { Keychain.string("relay.adminToken") }
        set { if let v = newValue, !v.isEmpty { Keychain.setString(v, for: "relay.adminToken") } else { Keychain.delete("relay.adminToken") } }
    }
    static var configured: Bool { !url.isEmpty && adminToken != nil }
}

/// Member side: who this iPhone is on a team.
struct MemberAccount: Codable, Equatable {
    var relayURL: String
    var memberID: String
    var name: String
    var role: String // admin, operator, viewer

    var canAct: Bool { role == "admin" || role == "operator" }
    var seesLogs: Bool { role == "admin" }
    var roleLabel: String { role.capitalized }

    private static let key = "member.account"
    private static let tokenKey = "member.token"

    static func load() -> MemberAccount? {
        guard let d = Keychain.get(key) else { return nil }
        return try? JSONDecoder().decode(MemberAccount.self, from: d)
    }
    func save() { if let d = try? JSONEncoder().encode(self) { Keychain.set(d, for: Self.key) } }
    static var token: String? {
        get { Keychain.string(tokenKey) }
        set { if let v = newValue { Keychain.setString(v, for: tokenKey) } else { Keychain.delete(tokenKey) } }
    }
    static func clear() {
        Keychain.delete(key)
        Keychain.delete(tokenKey)
        Keychain.delete("member.signingKey")
    }
}

/// Ed25519 key that signs every request; the agent checks it, so the relay cannot forge calls.
enum MemberIdentity {
    static var key: Curve25519.Signing.PrivateKey {
        if let raw = Keychain.get("member.signingKey"), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) { return k }
        let k = Curve25519.Signing.PrivateKey()
        Keychain.set(k.rawRepresentation, for: "member.signingKey")
        return k
    }
    static var publicKeyBase64: String { key.publicKey.rawRepresentation.base64EncodedString() }
}

// MARK: - Wire types

struct RelayServer: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let online: Bool
    let lastSeen: String?
}

struct RelayMember: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let role: String
    let scopes: [String: [String]]
    let publicKey: String?
    let device: String?
    let joined: Bool
    let joinedAt: String?
    let lastSeen: String?
    let aclVersion: Int
    let syncedVersion: Int
    let inviteId: String?
    let inviteExpiresAt: String?

    var needsSync: Bool { joined && syncedVersion < aclVersion }
}

struct RelayState: Decodable {
    let servers: [RelayServer]
    let members: [RelayMember]
}

struct InviteResult: Decodable {
    let inviteId: String
    let memberId: String
    let code: String
    let expiresAt: String
}

struct MemberMe: Decodable {
    let memberId: String
    let name: String
    let role: String
    let servers: [RelayServer]
    let activated: Bool
}

struct RelayError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? {
        if status == 401 { return message.isEmpty ? "Not authorized by the relay." : message }
        return message.isEmpty ? "Relay error \(status)" : message
    }
}

// MARK: - HTTP client

struct RelayClient {
    let baseURL: String
    let bearer: String?

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 50
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    func request(_ method: String, _ path: String, body: Data? = nil) async throws -> (Int, Data) {
        guard let url = URL(string: baseURL + path) else { throw RelayError(status: 0, message: "Invalid relay URL") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let bearer { r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await Self.session.data(for: r)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    func json<T: Decodable>(_ method: String, _ path: String, as: T.Type = T.self) async throws -> T {
        try Self.decode(try await request(method, path, body: nil))
    }

    func json<T: Decodable, B: Encodable>(_ method: String, _ path: String, _ body: B, as: T.Type = T.self) async throws -> T {
        try Self.decode(try await request(method, path, body: try JSON.encoder.encode(body)))
    }

    private static func decode<T: Decodable>(_ r: (Int, Data)) throws -> T {
        guard (200..<300).contains(r.0) else { throw RelayError(status: r.0, message: errorText(r.1)) }
        return try JSON.decoder.decode(T.self, from: r.1)
    }

    static func errorText(_ d: Data) -> String {
        (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String ?? ""
    }

    /// Signed call to an agent through the relay: method\npath\nts\nnonce\nsha256hex(body)
    func call(serverID: String, method: String, path: String, body: Data?) async throws -> Data {
        let bodyString = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let ts = Int(Date().timeIntervalSince1970)
        var nb = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, nb.count, &nb)
        let nonce = Data(nb).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let digest = SHA256.hash(data: Data(bodyString.utf8)).map { String(format: "%02x", $0) }.joined()
        let message = "\(method)\n\(path)\n\(ts)\n\(nonce)\n\(digest)"
        let sig = try MemberIdentity.key.signature(for: Data(message.utf8)).base64EncodedString()

        struct Call: Encodable { let method: String; let path: String; let body: String; let ts: Int; let nonce: String; let sig: String }
        let payload = try JSONEncoder().encode(Call(method: method, path: path, body: bodyString, ts: ts, nonce: nonce, sig: sig))
        let (code, out) = try await request("POST", "/m/v1/servers/\(serverID)/call", body: payload)
        guard (200..<300).contains(code) else {
            throw AgentAPI.HTTPError(status: code, message: Self.errorText(out))
        }
        return out
    }
}

// MARK: - Admin team operations

@Observable
@MainActor
final class TeamStore {
    var state: RelayState?
    var error: String?
    var loading = false

    private var client: RelayClient? {
        guard RelaySettings.configured else { return nil }
        return RelayClient(baseURL: RelaySettings.url, bearer: RelaySettings.adminToken)
    }

    var members: [RelayMember] { (state?.members ?? []).filter(\.joined) }
    var pending: [RelayMember] { (state?.members ?? []).filter { !$0.joined } }

    func load() async {
        guard let client else { state = nil; return }
        loading = true
        defer { loading = false }
        do {
            state = try await client.json("GET", "/admin/v1/state")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    struct MemberBody: Encodable { let name: String; let role: String; let scopes: [String: [String]] }

    func invite(name: String, role: String, scopes: [String: [String]]) async throws -> (link: String, expires: String) {
        guard let client else { throw RelayError(status: 0, message: "Set up the relay first") }
        let r: InviteResult = try await client.json("POST", "/admin/v1/invites", MemberBody(name: name, role: role, scopes: scopes))
        await load()
        return (Self.joinLink(code: r.code), r.expiresAt)
    }

    static func joinLink(code: String) -> String {
        var c = URLComponents()
        c.scheme = "srvmon"
        c.host = "join"
        c.queryItems = [URLQueryItem(name: "r", value: RelaySettings.url), URLQueryItem(name: "c", value: code)]
        return c.url?.absoluteString ?? ""
    }

    func update(_ m: RelayMember, role: String, scopes: [String: [String]], store: ServerStore) async throws {
        guard let client else { return }
        struct OK: Decodable { let ok: Bool }
        let _: OK = try await client.json("PUT", "/admin/v1/members/\(m.id)", MemberBody(name: m.name, role: role, scopes: scopes))
        await load()
        await sync(store: store)
    }

    func remove(_ m: RelayMember, store: ServerStore) async throws {
        guard let client else { return }
        if let inv = m.inviteId {
            let _ = try await client.request("DELETE", "/admin/v1/invites/\(inv)")
        }
        let _ = try await client.request("DELETE", "/admin/v1/members/\(m.id)")
        await load()
        await sync(store: store)
    }

    /// Connects an SSH server to the relay: registers it, then writes the relay settings into its agent.
    func enroll(_ s: ServerRecord, store: ServerStore) async throws {
        guard let client else { throw RelayError(status: 0, message: "Set up the relay first") }
        struct Body: Encodable { let id: String?; let name: String }
        struct Out: Decodable { let id: String; let secret: String }
        let out: Out = try await client.json("POST", "/admin/v1/servers", Body(id: s.relayServerID, name: s.name))
        struct AgentRelay: Encodable { let url: String; let serverId: String; let secret: String }
        try await store.api(for: s).send("PUT", "/v1/relay", AgentRelay(url: RelaySettings.url, serverId: out.id, secret: out.secret))
        var u = s
        u.relayServerID = out.id
        store.upsert(u)
        await load()
        await sync(store: store)
    }

    /// Pushes every member's role, scopes and key to each enrolled server over SSH.
    /// The agent only trusts this list, never the relay.
    func sync(store: ServerStore) async {
        guard let client, let state else { return }
        let enrolled = store.servers.filter { $0.auth != .relay && $0.installed && $0.relayServerID != nil }
        guard !enrolled.isEmpty else { return }
        struct AgentMember: Encodable { let id: String; let name: String; let role: String; let publicKey: String; let scopes: [String] }
        var failed = false
        for s in enrolled {
            guard let rid = s.relayServerID else { continue }
            let list = state.members.compactMap { m -> AgentMember? in
                guard m.joined, let pk = m.publicKey, let pats = m.scopes[rid] else { return nil }
                return AgentMember(id: m.id, name: m.name, role: m.role, publicKey: pk, scopes: pats)
            }
            do { try await store.api(for: s).send("PUT", "/v1/members", list) } catch { failed = true }
        }
        guard !failed else { return }
        struct V: Encodable { let version: Int }
        var changed = false
        for m in state.members where m.needsSync {
            _ = try? await client.request("POST", "/admin/v1/members/\(m.id)/synced", body: try? JSON.encoder.encode(V(version: m.aclVersion)))
            changed = true
        }
        if changed { await load() }
    }
}

// MARK: - Joining a team (member side)

enum TeamJoin {
    struct Link { let relay: String; let code: String }

    static func parse(_ s: String) -> Link? {
        guard let c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "srvmon", c.host == "join",
              let r = c.queryItems?.first(where: { $0.name == "r" })?.value,
              let code = c.queryItems?.first(where: { $0.name == "c" })?.value,
              r.hasPrefix("https://") || r.hasPrefix("http://127.0.0.1") || r.hasPrefix("http://localhost")
        else { return nil }
        return Link(relay: r, code: code)
    }

    static func redeem(_ link: Link) async throws -> MemberAccount {
        struct Body: Encodable { let code: String; let publicKey: String; let device: String }
        struct Out: Decodable { let memberId: String; let token: String; let name: String; let role: String }
        MemberAccount.clear() // fresh key for a fresh membership
        let device = await MainActor.run { UIDevice.current.name }
        let out: Out = try await RelayClient(baseURL: link.relay, bearer: nil)
            .json("POST", "/m/v1/redeem", Body(code: link.code, publicKey: MemberIdentity.publicKeyBase64, device: device))
        let acc = MemberAccount(relayURL: link.relay, memberID: out.memberId, name: out.name, role: out.role)
        MemberAccount.token = out.token
        acc.save()
        return acc
    }
}
