import Foundation
import CryptoKit

/// Links two iPhones exchange through the Camera app (both open this app):
///  - `srvmon://authorize?k=<key line>&n=<device>`: "this is my key" — scanned by a phone
///    that already has the servers; it appends the key to authorized_keys on them.
///  - `srvmon://import?s=<base64url json>`: "here are the servers" — scanned by the new
///    phone; it adds the records and connects with its own key.
enum PhoneLink {
    struct Authorize: Identifiable, Hashable {
        let key: String   // normalized "ssh-ed25519 AAAA… comment"
        let name: String  // the other phone's device name
        var id: String { key }
    }

    struct ServerExport: Codable, Hashable {
        let n: String      // name
        let h: String      // host
        let p: Int         // port
        let u: String      // username
        let x: Bool?       // externalAgent
    }

    struct Import: Identifiable, Hashable {
        let servers: [ServerExport]
        var id: String { servers.map { "\($0.u)@\($0.h):\($0.p)" }.joined(separator: ",") }
    }

    enum Parsed { case authorize(Authorize), importServers(Import) }

    static func authorizeLink(key: String, name: String) -> String {
        var c = URLComponents()
        c.scheme = "srvmon"
        c.host = "authorize"
        c.queryItems = [URLQueryItem(name: "k", value: key), URLQueryItem(name: "n", value: name)]
        return c.string ?? ""
    }

    static func importLink(_ servers: [ServerRecord]) -> String {
        let list = servers.map { ServerExport(n: $0.name, h: $0.host, p: $0.port, u: $0.username, x: $0.externalAgent == true ? true : nil) }
        let json = (try? JSONEncoder().encode(list)) ?? Data()
        let b64 = json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "srvmon://import?s=\(b64)"
    }

    static func parse(_ s: String) -> Parsed? {
        guard let c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), c.scheme == "srvmon" else { return nil }
        let q = c.queryItems ?? []
        switch c.host {
        case "authorize":
            guard let k = q.first(where: { $0.name == "k" })?.value, let key = validKey(k) else { return nil }
            let n = q.first(where: { $0.name == "n" })?.value?.trimmingCharacters(in: .whitespaces) ?? ""
            return .authorize(Authorize(key: key, name: n.isEmpty ? "iPhone" : String(n.prefix(40))))
        case "import":
            guard var b = q.first(where: { $0.name == "s" })?.value else { return nil }
            b = b.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            guard let d = Data(base64Encoded: b), let list = try? JSONDecoder().decode([ServerExport].self, from: d),
                  !list.isEmpty, list.count <= 50 else { return nil }
            let clean = list.filter { !$0.h.isEmpty && !$0.u.isEmpty && (1...65535).contains($0.p) }
            return clean.isEmpty ? nil : .importServers(Import(servers: clean))
        default:
            return nil
        }
    }

    /// Only an ed25519 key line as this app writes it: type, base64 blob, optional plain comment.
    /// Anything else (other types, options, whitespace tricks) is refused.
    static func validKey(_ s: String) -> String? {
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 || parts.count == 3, parts[0] == "ssh-ed25519",
              let blob = Data(base64Encoded: parts[1]), blob.count == 51 else { return nil }
        if parts.count == 3 {
            let ok = parts[2].allSatisfy { $0.isLetter || $0.isNumber || "._@-".contains($0) }
            guard ok, parts[2].count <= 64 else { return nil }
        }
        return parts.joined(separator: " ")
    }

    /// "ssh-ed25519 AAAA…" without the comment: what authorized_keys is searched for.
    static func keyCore(_ line: String) -> String {
        line.split(separator: " ").prefix(2).joined(separator: " ")
    }

    static func fingerprint(_ line: String) -> String {
        let parts = line.split(separator: " ")
        guard parts.count > 1, let blob = Data(base64Encoded: String(parts[1])) else { return "" }
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// Another iPhone whose key this phone put on servers. Kept so it can be revoked later.
struct AuthorizedPhone: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var key: String
    var addedAt = Date()
    var serverIDs: [UUID]
    var fingerprint: String { PhoneLink.fingerprint(key) }
}

extension ServerStore {
    private static let phonesKey = "phones.v1"

    static func loadPhones() -> [AuthorizedPhone] {
        guard let d = UserDefaults.standard.data(forKey: phonesKey),
              let l = try? JSONDecoder().decode([AuthorizedPhone].self, from: d) else { return [] }
        return l
    }

    func savePhones() {
        if let d = try? JSONEncoder().encode(authorizedPhones) { UserDefaults.standard.set(d, forKey: Self.phonesKey) }
    }

    /// Appends the key to the login user's own authorized_keys on each server (root's for a
    /// root login, srvmon's for a non-root one). Returns an error text per server that failed.
    func authorize(key: String, on servers: [ServerRecord]) async -> [UUID: String] {
        let core = PhoneLink.keyCore(key)
        let script = "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; "
            + "grep -qF \(shq(core)) ~/.ssh/authorized_keys || printf '%s\\n' \(shq(key)) >> ~/.ssh/authorized_keys"
        return await runOnEach(servers, script)
    }

    /// Removes every line holding that key. Never touches this iPhone's own key.
    func revoke(key: String, on servers: [ServerRecord]) async -> [UUID: String] {
        let core = PhoneLink.keyCore(key)
        guard core != PhoneLink.keyCore(AppIdentity.publicKeyLine) else { return [:] }
        let script = "f=~/.ssh/authorized_keys; if [ -f \"$f\" ]; then grep -vF \(shq(core)) \"$f\" > \"$f.srvmon\" || true; "
            + "cat \"$f.srvmon\" > \"$f\"; rm -f \"$f.srvmon\"; fi"
        return await runOnEach(servers, script)
    }

    private func runOnEach(_ servers: [ServerRecord], _ script: String) async -> [UUID: String] {
        var failures: [UUID: String] = [:]
        await withTaskGroup(of: (UUID, String?).self) { g in
            for s in servers where !s.isRelay {
                g.addTask {
                    do {
                        let (out, code) = try await self.session(for: s).run(script, timeout: .seconds(30))
                        return (s.id, code == 0 ? nil : (out.split(separator: "\n").last.map(String.init) ?? "exit \(code)"))
                    } catch {
                        return (s.id, friendlyError(error))
                    }
                }
            }
            for await (id, err) in g { if let err { failures[id] = err } }
        }
        return failures
    }

    /// Adds servers another iPhone sent. The records log in with this iPhone's key, which that
    /// phone has already put on the servers. Returns how many were new.
    @discardableResult
    func importServers(_ list: [PhoneLink.ServerExport]) -> Int {
        var added = 0
        for e in list {
            if servers.contains(where: { $0.host == e.h && $0.port == e.p && $0.username == e.u }) { continue }
            var name = e.n.isEmpty ? e.h : e.n
            var n = 2
            while servers.contains(where: { $0.name == name }) { name = "\(e.n) (\(n))"; n += 1 }
            var r = ServerRecord(name: name, host: e.h, port: e.p, username: e.u, auth: .appKey)
            r.installed = true
            r.externalAgent = e.x == true ? true : nil
            upsert(r)
            added += 1
        }
        return added
    }
}
