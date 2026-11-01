import SwiftUI

/// Colors and type from the design canvas.
enum Theme {
    static let bg = Color(hex: 0x0B0D10)
    static let surface = Color(hex: 0x14171C)
    static let surface2 = Color(hex: 0x1B1F26)
    static let border = Color(hex: 0x262B33)
    static let text = Color(hex: 0xECEEF1)
    static let text2 = Color(hex: 0xA3AAB4)
    static let text3 = Color(hex: 0x7D8590)
    static let accent = Color(hex: 0x5B9BFF)
    static let ok = Color(hex: 0x3DD68C)
    static let warn = Color(hex: 0xF5B544)
    static let crit = Color(hex: 0xFF6B6B)
    static let logBg = Color(hex: 0x07080A)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Bar / gauge color for a percentage.
    static func level(_ v: Double) -> Color {
        v >= 90 ? crit : v >= 80 ? warn : accent
    }

    static func valueText(_ v: Double) -> Color {
        v >= 90 ? crit : v >= 80 ? warn : text
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum Health: String, Codable {
    case healthy, warning, critical, offline, unknown

    var label: String {
        switch self {
        case .healthy: "Healthy"
        case .warning: "Warning"
        case .critical: "Critical"
        case .offline: "Offline"
        case .unknown: "Connecting"
        }
    }

    var color: Color {
        switch self {
        case .healthy: Theme.ok
        case .warning: Theme.warn
        case .critical, .offline: Theme.crit
        case .unknown: Theme.text2
        }
    }

    var rank: Int {
        switch self {
        case .offline: 0
        case .critical: 1
        case .warning: 2
        case .unknown: 3
        case .healthy: 4
        }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

struct StatusChip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .lineLimit(1)
    }
}

/// Shape differs per level so status is never told by color alone.
struct StatusMark: View {
    let health: Health
    var size: CGFloat = 9
    var body: some View {
        switch health {
        case .healthy:
            Circle().fill(health.color).frame(width: size, height: size)
        case .warning:
            RoundedRectangle(cornerRadius: 2).fill(health.color).frame(width: size - 1, height: size - 1)
        case .critical, .offline:
            Triangle().fill(health.color).frame(width: size + 1, height: size)
        case .unknown:
            Circle().stroke(health.color, lineWidth: 1.5).frame(width: size, height: size)
        }
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

struct MetricBar: View {
    let label: String
    let value: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).foregroundStyle(Theme.text2)
                Spacer()
                Text("\(Int(value.rounded()))%").font(Theme.mono(12, .medium)).foregroundStyle(Theme.valueText(value))
            }
            .font(.system(size: 12))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border)
                    Capsule().fill(Theme.level(value)).frame(width: g.size.width * min(max(value, 0), 100) / 100)
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(Int(value)) percent")
    }
}

struct RingGauge: View {
    let label: String
    let value: Double
    let sub: String
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Theme.border, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: min(max(value, 0), 100) / 100)
                    .stroke(Theme.level(value), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(value.rounded()))%").font(Theme.mono(16, .medium))
            }
            .frame(width: 72, height: 72)
            VStack(spacing: 1) {
                Text(label).font(.system(size: 13, weight: .semibold))
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .padding(.vertical, 14).padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.border))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(Int(value)) percent, \(sub)")
    }
}

struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { opt in
                Button { selection = opt.0 } label: {
                    Text(opt.1)
                        .font(.system(size: 13, weight: selection == opt.0 ? .semibold : .medium))
                        .foregroundStyle(selection == opt.0 ? Theme.text : Theme.text2)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(selection == opt.0 ? Theme.border : .clear, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == opt.0 ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var secondary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: secondary ? .medium : .semibold))
            .foregroundStyle(secondary ? Theme.text : Theme.bg)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(secondary ? Theme.surface : Theme.accent, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(secondary ? Theme.border : .clear))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

enum Fmt {
    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .memory)
    }

    static func uptime(_ s: Double) -> String {
        let d = Int(s) / 86400, h = (Int(s) % 86400) / 3600, m = (Int(s) % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func shortUptime(_ s: Double) -> String {
        let d = Int(s) / 86400
        return d > 0 ? "\(d)d" : uptime(s)
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    /// Parses Go/Docker RFC3339 (with or without nanoseconds).
    static func date(_ s: String?) -> Date? {
        guard var s, !s.isEmpty else { return nil }
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let frac = s[s.index(after: dot)..<end]
            if frac.count > 3 { s.replaceSubrange(s.index(after: dot)..<end, with: frac.prefix(3)) }
        }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }

    static func ago(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        return relative(d)
    }

    /// 45 s · 3 min 05 s · 1 h 04 min
    static func elapsed(_ secs: Int) -> String {
        if secs < 60 { return "\(secs) s" }
        if secs < 3600 { return String(format: "%d min %02d s", secs / 60, secs % 60) }
        return String(format: "%d h %02d min", secs / 3600, (secs % 3600) / 60)
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: .now)
    }

    static func logTime(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        return d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}
