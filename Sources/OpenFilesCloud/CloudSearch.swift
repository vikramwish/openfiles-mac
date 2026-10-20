import Foundation

/// An opaque continuation tied to this query and connected client session.
public struct CloudSearchCursor: Sendable {
    let query: String
    let provider: CloudProvider
    let generation: UUID
    let token: String
}

public struct CloudSearchPage: Sendable {
    public let items: [CloudItem]
    public let next: CloudSearchCursor?
}

public enum CloudSearchKind: String, CaseIterable, Identifiable, Sendable {
    case all = "All files", documents = "Documents", images = "Images", audio = "Audio", video = "Video", archives = "Archives"
    public var id: String { rawValue }
    public func matches(_ item: CloudItem) -> Bool {
        guard !item.isFolder else { return false }
        if self == .all { return true }
        let ext = (item.name as NSString).pathExtension.lowercased(), mime = item.mimeType ?? ""
        switch self {
        case .all: return true
        case .documents:
            return ["pdf", "txt", "md", "csv", "json", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "pages", "numbers", "key"].contains(ext)
                || ["application/vnd.google-apps.document", "application/vnd.google-apps.spreadsheet", "application/vnd.google-apps.presentation", "application/pdf"].contains(mime)
                || mime.hasPrefix("text/")
        case .images: return mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "svg", "raw"].contains(ext)
        case .audio: return mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "aiff", "flac", "ogg"].contains(ext)
        case .video: return mime.hasPrefix("video/") || ["mov", "mp4", "m4v", "avi", "mkv", "webm"].contains(ext)
        case .archives: return ["zip", "tar", "gz", "7z", "rar", "bz2", "xz"].contains(ext)
        }
    }
}

public enum CloudSearchSort: String, CaseIterable, Identifiable, Sendable {
    case provider = "Provider order", name = "Name", newest = "Newest first", largest = "Largest first"
    public var id: String { rawValue }
}

public enum CloudSearchResults {
    /// Filters/sorts loaded metadata only. Unknown sizes and dates sort last.
    public static func visible(_ items: [CloudItem], kind: CloudSearchKind = .all, sort: CloudSearchSort = .provider) -> [CloudItem] {
        var seen = Set<String>()
        let values = items.filter { kind.matches($0) && seen.insert($0.id).inserted }
        guard sort != .provider else { return values }
        return values.sorted {
            if sort == .largest, $0.size != $1.size { return ($0.size ?? -1) > ($1.size ?? -1) }
            if sort == .newest, $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
