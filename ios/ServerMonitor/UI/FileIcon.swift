import SwiftUI

/// What a file is, from its name: an SF Symbol and a colour per family.
struct FileKind {
    let symbol: String
    let color: Color

    static func of(_ name: String) -> FileKind {
        let lower = name.lowercased()
        switch lower {
        case "dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml":
            return FileKind(symbol: "shippingbox.fill", color: Color(hex: 0x2496ED))
        case "makefile", "cmakelists.txt":
            return FileKind(symbol: "hammer.fill", color: Theme.text3)
        case ".env", ".env.local", ".env.production", ".env.example", ".htpasswd":
            return FileKind(symbol: "key.fill", color: Theme.warn)
        default: break
        }
        return byExtension(extensionOf(lower))
    }

    /// "access.log.1" → "log", "app.tar.gz" → "gz", ".env" → "".
    static func extensionOf(_ lower: String) -> String {
        var base = lower
        while true {
            let ext = (base as NSString).pathExtension
            if ext.isEmpty { return "" }
            if ext.allSatisfy(\.isNumber) { base = (base as NSString).deletingPathExtension; continue }
            return ext
        }
    }

    static func byExtension(_ ext: String) -> FileKind {
        switch ext {
        case "ts", "tsx", "mts", "cts": return FileKind(symbol: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0x3178C6))
        case "js", "jsx", "mjs", "cjs": return FileKind(symbol: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0xF0DB4F))
        case "go": return FileKind(symbol: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0x00ADD8))
        case "py", "pyi": return FileKind(symbol: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0x4B8BBE))
        case "php": return FileKind(symbol: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0x8892BF))
        case "rb", "erb": return FileKind(symbol: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0xCC342D))
        case "java", "jar": return FileKind(symbol: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0xB07219))
        case "kt", "kts": return FileKind(symbol: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0xA97BFF))
        case "swift": return FileKind(symbol: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0xF05138))
        case "rs": return FileKind(symbol: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0xDEA584))
        case "c", "cpp", "cc", "h", "hpp", "m", "mm": return FileKind(symbol: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0x9AA5B1))
        case "cs": return FileKind(symbol: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0x3DD68C))
        case "sh", "bash", "zsh", "fish": return FileKind(symbol: "terminal.fill", color: Color(hex: 0x89E051))
        case "sql": return FileKind(symbol: "cylinder.fill", color: Color(hex: 0xE38C00))
        case "html", "htm": return FileKind(symbol: "globe", color: Color(hex: 0xE34C26))
        case "css", "scss", "sass", "less": return FileKind(symbol: "paintbrush.fill", color: Color(hex: 0x7B61C1))
        case "vue": return FileKind(symbol: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0x41B883))
        case "svelte": return FileKind(symbol: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0xFF3E00))
        case "json", "json5", "jsonc": return FileKind(symbol: "curlybraces", color: Theme.warn)
        case "yaml", "yml", "toml", "ini", "conf", "cfg", "properties", "xml", "plist", "service", "env":
            return FileKind(symbol: "gearshape.fill", color: Theme.text2)
        case "md", "markdown", "txt", "rtf", "rst", "adoc": return FileKind(symbol: "doc.text.fill", color: Theme.text2)
        case "pdf": return FileKind(symbol: "doc.richtext.fill", color: Color(hex: 0xE53935))
        case "doc", "docx", "odt", "pages": return FileKind(symbol: "doc.text.fill", color: Color(hex: 0x4A86E8))
        case "xls", "xlsx", "ods", "numbers", "csv", "tsv": return FileKind(symbol: "tablecells.fill", color: Color(hex: 0x34A853))
        case "ppt", "pptx", "odp", "key": return FileKind(symbol: "rectangle.on.rectangle.fill", color: Color(hex: 0xD24726))
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "ico", "bmp", "tiff", "avif":
            return FileKind(symbol: "photo.fill", color: Color(hex: 0xE91E63))
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar": return FileKind(symbol: "doc.zipper", color: Color(hex: 0xC48A3F))
        case "log", "out", "err": return FileKind(symbol: "doc.text.magnifyingglass", color: Theme.text3)
        case "mp4", "mov", "mkv", "avi", "webm", "m4v": return FileKind(symbol: "film.fill", color: Color(hex: 0x8E44AD))
        case "mp3", "wav", "flac", "ogg", "m4a", "aac": return FileKind(symbol: "music.note", color: Color(hex: 0x1ABC9C))
        case "db", "sqlite", "sqlite3", "mdb", "dump", "bak": return FileKind(symbol: "cylinder.fill", color: Color(hex: 0x7B61C1))
        case "pem", "crt", "cer", "pub", "p12", "pfx", "gpg", "asc": return FileKind(symbol: "key.fill", color: Theme.warn)
        case "so", "dylib", "dll", "exe", "bin", "o", "a", "deb", "rpm", "apk", "ipa", "img", "iso":
            return FileKind(symbol: "cpu.fill", color: Theme.text3)
        case "ttf", "otf", "woff", "woff2": return FileKind(symbol: "textformat", color: Theme.text2)
        case "lock": return FileKind(symbol: "lock.fill", color: Theme.text3)
        case "": return FileKind(symbol: "doc.fill", color: Theme.text3)
        default: return FileKind(symbol: "doc.fill", color: Theme.text2)
        }
    }
}

/// A small file-type badge: the extension in capitals (TSX, PDF, PNG…) on the
/// family's colour; the family symbol when there is no short extension.
struct FileBadge: View {
    let name: String

    var body: some View {
        let ext = FileKind.extensionOf(name.lowercased())
        let kind = FileKind.of(name)
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(kind.color.opacity(0.16))
            RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(kind.color.opacity(0.45), lineWidth: 1)
            if !ext.isEmpty && ext.count <= 4 {
                Text(ext.uppercased())
                    .font(.system(size: ext.count > 3 ? 7.5 : 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(kind.color)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 2)
            } else {
                Image(systemName: kind.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(kind.color)
            }
        }
        .frame(width: 30, height: 24)
        .accessibilityHidden(true)
    }
}
