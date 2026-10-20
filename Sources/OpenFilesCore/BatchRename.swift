import Foundation

public struct BatchRenameRow: Identifiable, Sendable {
    public var id: URL { source }
    public let source: URL
    public let preview: RenamePreview?
    public let problem: String?
}
public struct BatchRenamePreview: Identifiable, Sendable {
    public let id: UUID
    public let rows: [BatchRenameRow]
    let generation: UUID
}
public struct BatchRenameOutcome: Identifiable, Sendable {
    public var id: URL { source }
    public let source: URL
    public let destination: URL?
    public let message: String?
}
public struct BatchRenameReport: Sendable {
    public let outcomes: [BatchRenameOutcome]
    public var renamed: Int { outcomes.filter { $0.destination != nil }.count }
}

public enum BatchRenamePattern {
    public static func name(_ suggestion: String, prefix: String, modified: Date?) -> String {
        var parts: [String] = []
        if let modified {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
            parts.append(formatter.string(from: modified))
        }
        let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefix.isEmpty { parts.append(prefix) }
        parts.append(suggestion)
        return parts.joined(separator: " - ")
    }
}

extension FileLibrary {
    /// One batch owns all its previews; the single-file preview cache cannot evict its rows.
    public func previewBatchRename(_ urls: [URL]) async throws -> BatchRenamePreview {
        let unique = Array(Set(urls)).sorted { $0.path < $1.path }
        guard !unique.isEmpty, unique.count <= 50 else { throw OpenFilesError.message("Choose between 1 and 50 files per batch.") }
        let generation = embeddingGeneration
        var rows: [BatchRenameRow] = []
        for url in unique {
            try Task.checkCancellation()
            do {
                let preview = try await makeRenamePreview(url)
                rows.append(.init(source: url, preview: preview, problem: nil))
            } catch is CancellationError { throw CancellationError() }
            catch { rows.append(.init(source: url, preview: nil, problem: error.localizedDescription)) }
            guard generation == embeddingGeneration else { throw OpenFilesError.message("The search model changed. Analyze the batch again.") }
        }
        try Task.checkCancellation()
        let result = BatchRenamePreview(id: UUID(), rows: rows, generation: generation)
        guard batchRenamePreviews.count < 8 else { throw OpenFilesError.message("Close another batch review before analyzing more files.") }
        batchRenamePreviews[result.id] = result
        return result
    }

    public func discardBatchRename(_ id: UUID) { batchRenamePreviews[id] = nil }

    /// Validate the entire selection before any move; later per-file failures are reported without hiding successes.
    public func applyBatchRename(_ id: UUID, names: [URL: String]) async throws -> BatchRenameReport {
        guard let batch = batchRenamePreviews[id], batch.generation == embeddingGeneration,
              !names.isEmpty, Set(names.keys).isSubset(of: Set(batch.rows.filter { $0.preview != nil }.map(\.source))) else {
            throw OpenFilesError.message("The batch review expired or contains unreviewed files. Analyze again.")
        }
        var destinations = Set<String>()
        let selected = batch.rows.filter { names[$0.source] != nil }
        for row in selected {
            try Task.checkCancellation()
            let destination = try renameDestination(row.preview!, name: names[row.source]!)
            let key = destination.path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard destinations.insert(key).inserted else { throw OpenFilesError.message("Two selected files would have the same destination. Edit one of the names before applying.") }
        }
        batchRenamePreviews[id] = nil
        var outcomes: [BatchRenameOutcome] = []
        for row in selected {
            if Task.isCancelled || embeddingGeneration != batch.generation {
                outcomes.append(.init(source: row.source, destination: nil, message: "Stopped before renaming this file. Analyze again to continue.")); continue
            }
            do {
                let result = try await performRename(row.preview!, name: names[row.source]!)
                outcomes.append(.init(source: row.source, destination: result.destination, message: result.indexWarning))
            } catch { outcomes.append(.init(source: row.source, destination: nil, message: error.localizedDescription)) }
        }
        return BatchRenameReport(outcomes: outcomes)
    }
}
