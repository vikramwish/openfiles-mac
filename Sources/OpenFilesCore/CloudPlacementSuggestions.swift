import Foundation

public struct CloudPlacementSuggestion: Identifiable, Sendable {
    public let id: UUID
    public let source: URL
    public let size: Int64
    public let reason: String
}

/// Metadata-only recommendations. No content leaves the device until an upload is approved.
public enum CloudPlacementSuggestions {
    public static func suggest(_ files: [FileRecord], now: Date = Date(), limit: Int = 5) -> [CloudPlacementSuggestion] {
        let large: Int64 = 25 * 1_024 * 1_024
        let old = now.addingTimeInterval(-90 * 24 * 60 * 60)
        var seen = Set<URL>()
        return files.filter { file in
            guard file.url.isFileURL, !file.isProject, !file.sensitive,
                  !FileRules.sensitive(file.name), file.size > 0 else { return false }
            let parts = file.url.standardizedFileURL.pathComponents
            // Files already in provider-managed folders should not be offered for another upload.
            for index in parts.indices.dropLast() where parts[index] == "Library" {
                if ["CloudStorage", "Mobile Documents"].contains(parts[index + 1]) { return false }
            }
            return file.size >= large || (file.size >= 1_024 * 1_024 && file.modified <= old)
        }.sorted {
            if $0.size != $1.size { return $0.size > $1.size }
            if $0.modified != $1.modified { return $0.modified < $1.modified }
            return $0.url.path < $1.url.path
        }.filter { seen.insert($0.url.standardizedFileURL).inserted }
        .prefix(max(0, limit)).map {
            CloudPlacementSuggestion(id: $0.id, source: $0.url, size: $0.size,
                reason: $0.size >= large ? "Large file · consider storing a cloud copy" : "Last modified over 90 days ago · consider a cloud copy")
        }
    }
}
