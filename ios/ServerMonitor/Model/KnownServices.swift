import SwiftUI

/// Services people run on a server and recognise by name. A systemd unit that matches one of
/// the patterns is shown with this title and icon in the "Known services" section; everything
/// else stays in the plain list. Matching is on the unit name without ".service", lowercase,
/// and ignores an instance suffix ("php8.2-fpm", "postgresql@14-main", "mariadb").
struct KnownService: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let color: Color
    let patterns: [String]   // prefixes of the unit name

    static let all: [KnownService] = [
        .init(id: "nginx", title: "Nginx", icon: "globe", color: Color(hex: 0x3DD68C), patterns: ["nginx"]),
        .init(id: "apache", title: "Apache", icon: "globe", color: Color(hex: 0xE05A5A), patterns: ["apache2", "httpd"]),
        .init(id: "caddy", title: "Caddy", icon: "globe", color: Color(hex: 0x22B5F5), patterns: ["caddy"]),
        .init(id: "haproxy", title: "HAProxy", icon: "arrow.triangle.branch", color: Color(hex: 0x7B61FF), patterns: ["haproxy"]),
        .init(id: "traefik", title: "Traefik", icon: "arrow.triangle.branch", color: Color(hex: 0x24A1C1), patterns: ["traefik"]),
        .init(id: "mysql", title: "MySQL / MariaDB", icon: "cylinder.split.1x2", color: Color(hex: 0xF5B544), patterns: ["mysql", "mariadb", "mysqld"]),
        .init(id: "postgres", title: "PostgreSQL", icon: "cylinder.split.1x2", color: Color(hex: 0x5B9BFF), patterns: ["postgresql", "postgres"]),
        .init(id: "mongodb", title: "MongoDB", icon: "leaf", color: Color(hex: 0x3DD68C), patterns: ["mongod", "mongodb"]),
        .init(id: "redis", title: "Redis", icon: "bolt.horizontal", color: Color(hex: 0xFF6B6B), patterns: ["redis", "redis-server", "valkey"]),
        .init(id: "memcached", title: "Memcached", icon: "memorychip", color: Color(hex: 0xA3AAB4), patterns: ["memcached"]),
        .init(id: "elasticsearch", title: "Elasticsearch", icon: "magnifyingglass", color: Color(hex: 0xF5B544), patterns: ["elasticsearch", "opensearch"]),
        .init(id: "rabbitmq", title: "RabbitMQ", icon: "tray.2", color: Color(hex: 0xFF8A3D), patterns: ["rabbitmq"]),
        .init(id: "php", title: "PHP-FPM", icon: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0x8892BF), patterns: ["php"]),
        .init(id: "node", title: "Node.js app", icon: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0x3DD68C), patterns: ["node", "pm2"]),
        .init(id: "docker", title: "Docker", icon: "shippingbox.fill", color: Theme.docker, patterns: ["docker", "containerd"]),
        .init(id: "ssh", title: "SSH", icon: "terminal", color: Color(hex: 0xA3AAB4), patterns: ["ssh", "sshd"]),
        .init(id: "fail2ban", title: "fail2ban", icon: "shield.lefthalf.filled", color: Color(hex: 0x5B9BFF), patterns: ["fail2ban"]),
        .init(id: "firewall", title: "Firewall", icon: "shield", color: Color(hex: 0x5B9BFF), patterns: ["ufw", "firewalld", "nftables"]),
        .init(id: "cron", title: "Cron", icon: "clock", color: Color(hex: 0xA3AAB4), patterns: ["cron", "crond"]),
        .init(id: "mail", title: "Mail", icon: "envelope", color: Color(hex: 0xA3AAB4), patterns: ["postfix", "dovecot", "exim4"]),
        .init(id: "ntp", title: "Time sync", icon: "clock.arrow.circlepath", color: Color(hex: 0xA3AAB4), patterns: ["chrony", "chronyd", "systemd-timesyncd", "ntp"]),
    ]

    /// "php8.2-fpm.service" → PHP-FPM, "postgresql@14-main.service" → PostgreSQL, "nginx.service" → Nginx.
    static func match(_ unit: String) -> KnownService? {
        var n = unit.lowercased()
        if n.hasSuffix(".service") { n.removeLast(8) }
        if let at = n.firstIndex(of: "@") { n = String(n[..<at]) }
        return all.first { k in
            k.patterns.contains { p in
                n == p || (n.hasPrefix(p) && Self.boundary(n, after: p))
            }
        }
    }

    /// The character after the prefix must not continue a name: "php" matches "php8.2-fpm" and
    /// "nginx" matches "nginx-proxy", but "ssh" does not match "sshguard" and "node" not "node_exporter".
    private static func boundary(_ n: String, after p: String) -> Bool {
        let c = n[n.index(n.startIndex, offsetBy: p.count)]
        return !c.isLetter && c != "_"
    }
}

extension Snapshot {
    /// Known services first by their catalogue order, each with its live unit.
    var knownServices: [(known: KnownService, unit: ServiceInfo)] {
        var out: [(KnownService, ServiceInfo)] = []
        for s in services where s.load != "not-found" {
            if let k = KnownService.match(s.name) { out.append((k, s)) }
        }
        let order = Dictionary(uniqueKeysWithValues: KnownService.all.enumerated().map { ($1.id, $0) })
        return out.sorted { (order[$0.0.id] ?? 0, $0.1.name) < (order[$1.0.id] ?? 0, $1.1.name) }
    }
}
