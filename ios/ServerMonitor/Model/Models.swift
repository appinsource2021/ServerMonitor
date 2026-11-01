import Foundation

// MARK: - Saved servers (no secrets here; those live in the Keychain)

enum AuthKind: String, Codable {
    case appKey      // the app's own ed25519 key, installed into authorized_keys
    case importedKey // a private key the user pasted/imported
    case password
    case relay       // team member: no SSH, reached through the relay
}

struct ServerRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String = "root"
    var auth: AuthKind
    var arch: String?
    var agentVersion: String?
    var installed = false
    var addedAt = Date()
    /// Admin: id of this server on the relay once connected. Member: the server to call.
    var relayServerID: String?
    /// Member servers: is the agent connected to the relay right now.
    var relayOnline: Bool?

    var isRelay: Bool { auth == .relay }
}

// MARK: - Agent API (mirrors srvmon-agent JSON, snake_case → camelCase)

struct Summary: Decodable {
    let snapshot: Snapshot
    let status: AgentStatus
    let alerts: [AgentAlert]
    let containerCount: ContainerCount
    let failedServices: Int
    let history: [HistoryPoint]
}

struct AgentStatus: Decodable {
    let level: String
    let critical: Int
    let warning: Int
}

struct ContainerCount: Decodable {
    let total: Int
    let running: Int
    let problems: Int
}

struct Snapshot: Decodable {
    let time: String
    let host: HostInfo
    let uptimeSeconds: Double
    let cpuPercent: Double
    let load: [Double]
    let memory: MemInfo
    let disks: [DiskInfo]
    let net: NetRate
    let dockerAvailable: Bool
    let dockerError: String?
    let containers: [ContainerInfo]
    let systemdAvailable: Bool
    let services: [ServiceInfo]
    let peers: [PeerStatus]

    var rootDisk: DiskInfo? { disks.first { $0.mount == "/" } ?? disks.first }
    var maxDiskPercent: Double { disks.map(\.percent).max() ?? 0 }
}

struct HostInfo: Decodable {
    let name: String
    let hostname: String
    let os: String
    let kernel: String
    let arch: String
    let cpus: Int
    let agentVersion: String
}

struct MemInfo: Decodable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let availableBytes: UInt64
    let percent: Double
}

struct DiskInfo: Decodable, Identifiable {
    let mount: String
    let totalBytes: UInt64
    let usedBytes: UInt64
    let freeBytes: UInt64
    let percent: Double
    var id: String { mount }
}

struct NetRate: Decodable {
    let rxBytesPerSec: Double
    let txBytesPerSec: Double
}

struct ContainerInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let state: String
    let status: String
    let health: String?
    let exitCode: Int
    let oomKilled: Bool
    let restartCount: Int
    let restartPolicy: String
    let startedAt: String?
    let finishedAt: String?
    let cpuPercent: Double
    let memBytes: UInt64
    let memLimitBytes: UInt64
    let composeProject: String?
    let composeService: String?
    let ports: [String]
    let ignored: Bool?

    var health_: Health {
        if state == "dead" || (state == "exited" && exitCode != 0 && exitCode != 143) || oomKilled && state == "exited" { return .critical }
        if state == "restarting" || health == "unhealthy" { return .warning }
        if state == "running" { return .healthy }
        return .unknown
    }

    var stateLine: String {
        switch state {
        case "exited":
            let when = Fmt.ago(finishedAt)
            return "Exited (\(exitCode))" + (oomKilled ? " · OOM" : "") + (when.isEmpty ? "" : " · \(when)")
        case "restarting":
            return "Restarting · \(restartCount) restarts"
        case "running":
            var s = status.replacingOccurrences(of: " (healthy)", with: "").replacingOccurrences(of: " (unhealthy)", with: "")
            if let h = health, !h.isEmpty { s += " · \(h)" }
            return s
        default:
            return status
        }
    }
}

struct ServiceInfo: Decodable, Identifiable, Hashable {
    let name: String
    let load: String
    let active: String
    let sub: String
    let description: String
    var id: String { name }

    var health: Health {
        switch active {
        case "failed": .critical
        case "active": .healthy
        case "activating", "deactivating", "reloading": .warning
        default: .unknown
        }
    }
}

struct PeerStatus: Decodable {
    let name: String
    let host: String
    let port: Int
    let reachable: Bool
    let latencyMs: Double
    let error: String?
}

struct HistoryPoint: Decodable, Identifiable {
    let t: Int64
    let cpu: Double
    let mem: Double
    var id: Int64 { t }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }
}

struct AgentAlert: Decodable, Identifiable, Hashable {
    let key: String
    let server: String
    let severity: String
    let title: String
    let message: String
    let container: String?
    let service: String?
    let since: String
    let resolved: String?
    let notified: Bool
    var id: String { server + "|" + key + "|" + since }

    var health: Health { severity == "critical" ? .critical : .warning }
}

struct AlertsResponse: Decodable {
    let active: [AgentAlert]
    let history: [AgentAlert]
}

struct LogLine: Decodable, Hashable {
    let time: String?
    let stream: String
    let text: String

    enum Level { case info, warn, error }
    var level: Level {
        let t = text.lowercased()
        if stream == "stderr" && (t.contains("error") || t.contains("fatal") || t.contains("panic") || t.contains("killed")) { return .error }
        if t.contains("error") || t.contains("fatal") || t.contains("panic") || t.contains("exception") || t.contains(" err ") || t.hasPrefix("err") { return .error }
        if t.contains("warn") { return .warn }
        return .info
    }
}

struct LogsResponse: Decodable {
    let lines: [LogLine]
}

struct ContainersResponse: Decodable {
    let available: Bool
    let containers: [ContainerInfo]
}

// MARK: - Rules / config

struct ThresholdRule: Codable, Hashable {
    var enabled: Bool
    var percent: Double
    var forSeconds: Int
}

struct ToggleRule: Codable, Hashable {
    var enabled: Bool
    var forSeconds: Int
}

struct RestartRule: Codable, Hashable {
    var enabled: Bool
    var count: Int
    var windowSeconds: Int
}

struct Rules: Codable, Hashable {
    var cpu: ThresholdRule
    var memory: ThresholdRule
    var disk: ThresholdRule
    var containerDown: ToggleRule
    var unhealthy: ToggleRule
    var restartLoop: RestartRule
    var systemdFailed: ToggleRule
    var peerUnreachable: ToggleRule
    var cooldownSeconds: Int
    var notifyResolved: Bool
}

struct AgentConfig: Decodable {
    struct APNs: Decodable {
        let configured: Bool
        let keyId: String
    }
    let name: String
    let allowActions: Bool
    let rules: Rules
    let apns: APNs
}

struct Peer: Codable {
    let name: String
    let host: String
    let port: Int
}

enum JSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}

// MARK: - Health check & disk analysis (agent ≥ 0.3)

struct HealthCheckItem: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let status: String // ok, warn, fail, skip
    let detail: String
    let hint: String?

    var health: Health {
        switch status {
        case "ok": .healthy
        case "warn": .warning
        case "fail": .critical
        default: .unknown
        }
    }
}

struct HealthReport: Decodable {
    let server: String
    let time: String
    let durationMs: Int
    let overall: String
    let checks: [HealthCheckItem]
}

struct DiskEntry: Decodable, Identifiable, Hashable {
    let path: String
    let name: String
    let bytes: UInt64
    var id: String { path }
}

struct DiskScan: Decodable {
    let path: String
    let status: String // running, done, error
    let error: String?
    let startedAt: String
    let finishedAt: String?
    let totalBytes: UInt64
    let entries: [DiskEntry]
    let largestFiles: [DiskEntry]
}

struct DockerDiskItem: Decodable, Identifiable, Hashable {
    let name: String
    let bytes: UInt64
    let reclaimableBytes: UInt64
    let detail: String?
    var id: String { name }
}

struct DockerDisk: Decodable {
    let available: Bool
    let error: String?
    let images: DockerDiskItem
    let containers: DockerDiskItem
    let volumes: DockerDiskItem
    let buildCache: DockerDiskItem
    let logs: DockerDiskItem
    let topImages: [DockerDiskItem]
    let topVolumes: [DockerDiskItem]
    let topLogs: [DockerDiskItem]
    let dataRoot: String?
    let totalBytes: UInt64
    let reclaimableBytes: UInt64
}

struct CleanupItem: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let category: String // safe, review
    let bytes: UInt64
    let paths: [String]?
    let inUse: String?

    var isSafe: Bool { category == "safe" }
}

struct CleanupScanResponse: Decodable { let items: [CleanupItem] }

struct CleanupResult: Decodable, Identifiable, Hashable {
    let id: String
    let freedBytes: UInt64
    let error: String?
}

struct CleanupRunResponse: Decodable {
    let results: [CleanupResult]
    let freedBytes: UInt64
}
