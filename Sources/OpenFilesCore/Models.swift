import Foundation

public struct FileRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var root: URL
    public var size: Int64
    public var modified: Date
    public var isProject: Bool
    public var sensitive: Bool
    public var vector: [Double]?
    public var name: String { url.lastPathComponent }
    public var category: String { isProject ? "Project" : FileRules.category(url) }
}

public struct FileVersion: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var source: URL
    public var message: String
    public var created: Date
    public var digest: String
    public var name: String { source.lastPathComponent }
}

public struct MoveProposal: Identifiable, Sendable {
    public var id: UUID
    public var source: URL
    public var destination: URL
    public var digest: String
}

public struct LibraryState: Codable, Sendable {
    public var roots: [URL] = []
    public var files: [FileRecord] = []
    public var versions: [FileVersion] = []
    public var autoOrganize: Bool = false
    public init() {}
}

public struct ScanReport: Sendable {
    public let state: LibraryState
    public let skipped: Int
    public let embeddingsAvailable: Bool
}

public struct OrganizationReport: Sendable {
    public var moved: Int = 0
    public var errors: [String] = []
}

public struct VaultState: Sendable {
    public let exists: Bool
    public let mounted: Bool
    public init(exists: Bool, mounted: Bool) { self.exists = exists; self.mounted = mounted }
}

public enum OpenFilesError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

public enum FileRules {
    public static let textExtensions: Set<String> = ["txt", "md", "csv", "json", "swift", "py", "js", "ts", "tsx", "html", "css", "yaml", "yml", "xml", "rtf"]
    public static let packageExtensions: Set<String> = ["app", "band", "logicx", "imovielibrary", "photoslibrary", "pages", "numbers", "key", "sparsebundle"]
    public static func sensitive(_ text: String) -> Bool {
        text.range(of: #"passport|password|secret|credential|private.?key|tax.?return|bank.?statement|social.?security|medical|\.pem$|\.key$|-----BEGIN .*PRIVATE KEY-----|\b\d{3}-\d{2}-\d{4}\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    public static func category(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "svg", "webp": return "Images"
        case "mov", "mp4", "m4v", "avi": return "Video"
        case "wav", "mp3", "aiff", "m4a", "flac": return "Audio"
        case "zip", "tar", "gz", "dmg": return "Archives"
        default: return "Documents"
        }
    }
    public static func contains(_ parent: URL, _ child: URL) -> Bool {
        let p = parent.standardizedFileURL.path
        let c = child.standardizedFileURL.path
        return c == p || c.hasPrefix(p == "/" ? "/" : p + "/")
    }
    public static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let norm = sqrt(a.reduce(0) { $0 + $1 * $1 } * b.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? dot / norm : 0
    }
}
