import Foundation
import Accelerate

public struct FileRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var root: URL
    public var size: Int64
    public var modified: Date
    public var isProject: Bool
    public var sensitive: Bool
    public var vector: [Double]?
    public var indexMetadata: FileIndexMetadata? = nil
    public var searchTerms: [String]? = nil
    public var imageContent: ImageContentIndex? = nil
    public var name: String { url.lastPathComponent }
    public var category: String { url.pathExtension.lowercased() == "photoslibrary" ? "Photos Library" : isProject ? "Project" : FileRules.category(url) }
    private enum CodingKeys: String, CodingKey { case id, url, root, size, modified, isProject, sensitive, vector, indexMetadata, searchTerms, imageContent }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); url = try c.decode(URL.self, forKey: .url); root = try c.decode(URL.self, forKey: .root)
        size = try c.decode(Int64.self, forKey: .size); modified = try c.decode(Date.self, forKey: .modified)
        isProject = try c.decode(Bool.self, forKey: .isProject); sensitive = try c.decode(Bool.self, forKey: .sensitive)
        imageContent = try c.decodeIfPresent(ImageContentIndex.self, forKey: .imageContent)
        searchTerms = try c.decodeIfPresent([String].self, forKey: .searchTerms)
        vector = try c.decodeIfPresent([Double].self, forKey: .vector); indexMetadata = try c.decodeIfPresent(FileIndexMetadata.self, forKey: .indexMetadata)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(url, forKey: .url); try c.encode(root, forKey: .root)
        try c.encode(size, forKey: .size); try c.encode(modified, forKey: .modified)
        try c.encode(isProject, forKey: .isProject); try c.encode(sensitive, forKey: .sensitive)
        try c.encodeIfPresent(indexMetadata, forKey: .indexMetadata)
        try c.encodeIfPresent(searchTerms, forKey: .searchTerms)
        try c.encodeIfPresent(imageContent, forKey: .imageContent)
        // New vectors live once in immutable content-addressed objects, not in every file entry.
        if indexMetadata?.objectKey == nil { try c.encodeIfPresent(vector, forKey: .vector) }
    }
    public init(id: UUID, url: URL, root: URL, size: Int64, modified: Date, isProject: Bool, sensitive: Bool, vector: [Double]?, indexMetadata: FileIndexMetadata? = nil, searchTerms: [String]? = nil) {
        self.id = id; self.url = url; self.root = root; self.size = size; self.modified = modified; self.isProject = isProject; self.sensitive = sensitive; self.vector = vector; self.indexMetadata = indexMetadata; self.searchTerms = searchTerms
    }

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
    public var indexSettings: IndexSettings?
    public var lastIndexReport: IndexProgress?
    public var smartCollections: [SmartCollection]?
    public init() {}
}

public struct ScanReport: Sendable {
    public let state: LibraryState
    public let skipped: Int
    public let embeddingsAvailable: Bool
    public let progress: IndexProgress
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
    /// Photos owns the contents of its library bundle. Treat it as one item.
    public static func photoLibrary(containing url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if current.pathExtension.lowercased() == "photoslibrary" { return current }
            current.deleteLastPathComponent()
        }
        return nil
    }
    private static let sensitiveExpression = try! NSRegularExpression(pattern: #"passport|password|secret|credential|private.?key|tax.?return|bank.?statement|social.?security|medical|\.pem$|\.key$|-----BEGIN .*PRIVATE KEY-----|\b\d{3}-\d{2}-\d{4}\b"#, options: [.caseInsensitive])
    public static func sensitive(_ text: String) -> Bool { sensitiveExpression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
    public static func category(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "photoslibrary": return "Photos Library"
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
    public static func cosine(_ a: [Double], _ b: [Double]) -> Double { VectorMath.cosine(a, b) }
}
