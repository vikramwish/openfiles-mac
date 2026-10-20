import Foundation
import Darwin

public enum CleanupKind: String, Codable, Sendable {
    case screenshot = "Older screenshot", duplicate = "Exact duplicate", installer = "Old installer", archive = "Old downloaded archive", related = "Similar older document"
}
public struct CleanupFile: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let bytes: Int64
    public let modified: Date
    public let kind: CleanupKind
    public let evidence: String
    public let relatedURL: URL?
    public var reviewScore: Int = 0
    fileprivate let stamp: FileStamp
    fileprivate let digest: String
}
public struct DuplicateSet: Identifiable, Sendable {
    public let id: String
    public let files: [CleanupFile]
    public var possibleSavings: Int64 { files.dropFirst().reduce(0) { $0 + $1.bytes } }
}
public struct CleanupReview: Sendable {
    public let id: UUID
    public let scope: URL
    public var duplicates: [DuplicateSet] = []
    public var suggestions: [CleanupFile] = []
    public var skipped = 0
    public var checked = 0
    public var limited = false
    public var usesEmbeddings = false
    public var files: [CleanupFile] { duplicates.flatMap(\.files) + suggestions }
}
public struct CleanupReceipt: Codable, Identifiable, Sendable {
    public let id: UUID
    public let original: URL
    public let trashed: URL
    public let date: Date
}
public struct CleanupResult: Sendable {
    public var receipts: [CleanupReceipt] = []
    public var errors: [String] = []
}
public protocol CleanupTrash: Sendable {
    func moveToTrash(_ url: URL) throws -> URL
}
public struct SystemCleanupTrash: CleanupTrash {
    public init() {}
    public func moveToTrash(_ url: URL) throws -> URL {
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        guard let destination else { throw OpenFilesError.message("File moved to Trash; Finder can restore it.") }
        return destination as URL
    }
}

/// Owns the review capability: callers can select IDs, never supply executable paths or hashes.
public actor CleanupService {
    private let appData: URL
    private let trash: any CleanupTrash
    private let screenshotMetadata: any ScreenshotMetadataProvider
    private var review: CleanupReview?
    private var exclusions: [URL] = []
    private var scanRoots: [URL] = []
    private var digestCache: [String: (FileStamp, String)] = [:]
    public init(directory: URL, trash: any CleanupTrash = SystemCleanupTrash(), screenshotMetadata: any ScreenshotMetadataProvider = SystemScreenshotMetadata()) {
        appData = directory.canonical; self.trash = trash; self.screenshotMetadata = screenshotMetadata
    }
    public func cancelReview() { review = nil }
    public func preview(files: [FileRecord], scope: URL, excluding protected: [URL] = [], now: Date = Date(), limit: Int = 5000, scopes: [URL]? = nil) throws -> CleanupReview {
        review = nil
        let scope = scope.canonical
        scanRoots = MacScanScopes.reduce(scopes ?? [scope])
        exclusions = protected.map(\.canonical)
        var plan = CleanupReview(id: UUID(), scope: scope)
        var safe: [(FileRecord, FileStamp)] = []
        var folderProtection: [String: Bool] = [:]
        var seen = Set<String>()
        for file in files.sorted(by: { $0.url.path < $1.url.path }) {
            try Task.checkCancellation()
            let url = file.url.standardizedFileURL
            guard scanRoots.contains(where: { syncContains($0, url) }), seen.insert(url.path).inserted else { continue }
            if safe.count >= max(0, limit) { plan.limited = true; break }
            guard !file.sensitive, !file.isProject, !FileRules.sensitive(file.name),
                  SemanticOrganizer.exclusion(url, roots: scanRoots, output: appData, appData: appData, excluded: exclusions, folderProtection: &folderProtection) == nil,
                  let stamp = try? safeStamp(url, scope: scope), stamp.size > 0, stamp.size <= 256 * 1024 * 1024,
                  file.indexMetadata == nil || file.indexMetadata?.stamp == stamp else { plan.skipped += 1; continue }
            var normalized = file; normalized.url = url
            safe.append((normalized, stamp))
        }
        // Only equal-size buckets require disk hashing for duplicate detection.
        let buckets = Dictionary(grouping: safe, by: { $0.1.size })
        var groups: [String: [CleanupFile]] = [:]
        var hashedBytes: Int64 = 0
        let hashBudget: Int64 = 2 * 1024 * 1024 * 1024
        var duplicatePaths = Set<String>()
        for bucket in buckets.values where bucket.count > 1 {
            for (file, stamp) in bucket {
                try Task.checkCancellation()
                guard hashedBytes + stamp.size <= hashBudget else { plan.limited = true; continue }
                hashedBytes += stamp.size
                guard let digest = try? checkedDigest(file.url, stamp: stamp, scope: scope, allowCache: true) else { plan.skipped += 1; continue }
                plan.checked += 1
                groups[digest, default: []].append(CleanupFile(id: UUID(), url: file.url, bytes: stamp.size, modified: stamp.modified, kind: .duplicate,
                    evidence: "Same size and SHA-256 file contents. Names, metadata and references may differ; review which copy to keep.", relatedURL: nil, stamp: stamp, digest: digest))
            }
        }
        for (digest, files) in groups where files.count > 1 {
            let sorted = files.sorted { $0.url.path < $1.url.path }
            plan.duplicates.append(DuplicateSet(id: digest, files: sorted))
            duplicatePaths.formUnion(files.map { $0.url.path })
        }
        plan.duplicates.sort { $0.possibleSavings == $1.possibleSavings ? $0.id < $1.id : $0.possibleSavings > $1.possibleSavings }
        let age = now.addingTimeInterval(-90 * 86400)
        // Bound similarity comparisons. A vector match is review evidence, never proof of redundancy.
        let documents = safe.filter { !$0.0.sensitive && $0.0.vector != nil && ["pdf", "txt", "md", "docx", "rtf", "pages"].contains($0.0.url.pathExtension.lowercased()) }
            .sorted { $0.1.modified > $1.1.modified }.prefix(500)
        var similarityComparisons = 0
        var screenshotsAnalyzed = 0
        var metadataCache: [String: ScreenshotFileMetadata] = [:]
        func metadataForScreenshot(_ url: URL) -> ScreenshotFileMetadata {
            if let cached = metadataCache[url.path] { return cached }
            let value = screenshotMetadata.metadata(for: url); metadataCache[url.path] = value; return value
        }
        for (file, stamp) in safe where !duplicatePaths.contains(file.url.path) && stamp.modified < age {
            try Task.checkCancellation()
            let ext = file.url.pathExtension.lowercased()
            let downloaded = file.url.deletingLastPathComponent().pathComponents.contains { $0.lowercased() == "downloads" }
            var kind: CleanupKind?, evidence = "", related: URL?, reviewScore = 0
            if ScreenshotReview.imageExtensions.contains(ext) {
                let metadata = metadataForScreenshot(file.url)
                if let source = ScreenshotReview.source(for: file.url, metadata: metadata), !ScreenshotReview.containsImportantContent([file.name]) {
                    var signals = ScreenshotSignals(source: source, created: metadata.created, modified: stamp.modified, lastUsed: metadata.lastUsed, kept: !metadata.tags.isEmpty, contentTerms: file.imageContent.map { $0.textTerms + Array($0.subjectTerms) })
                    if ScreenshotReview.isOldUnkept(signals, now: now) {
                        if signals.contentTerms == nil {
                            guard screenshotsAnalyzed < 100 else { plan.limited = true; continue }
                            screenshotsAnalyzed += 1
                            signals.contentTerms = try? PhotoMediaAnalysis.terms(at: file.url)
                        }
                        if let terms = signals.contentTerms,
                           let match = safe.first(where: { other in
                               other.1.modified > stamp.modified && other.0.url != file.url &&
                               ScreenshotReview.source(for: other.0.url, metadata: metadataForScreenshot(other.0.url)) != nil &&
                               ScreenshotReview.textOverlap(terms, other.0.imageContent?.textTerms ?? [])
                           }) {
                            signals.hasNewerRelatedCapture = true; related = match.0.url
                        }
                        if let assessment = ScreenshotReview.assess(signals, now: now) {
                            kind = .screenshot; evidence = assessment.evidence; reviewScore = assessment.score
                        }
                    }
                }
            } else if downloaded && ["dmg", "pkg", "iso"].contains(ext) {
                kind = .installer; evidence = "Installer in Downloads, last modified over 90 days ago. Check whether you still need it. Modification time does not show last use."
            } else if downloaded && ["zip", "tar", "gz", "7z", "rar"].contains(ext) {
                kind = .archive; evidence = "Archive in Downloads, last modified over 90 days ago. Its contents may still be needed; no extraction or redundancy is assumed."
            } else if let vector = file.vector, let engine = file.indexMetadata?.engine, similarityComparisons < 100_000 {
                let candidates = documents.filter { $0.0.url != file.url && $0.1.modified > stamp.modified && $0.0.indexMetadata?.engine == engine && $0.0.url.pathExtension.lowercased() == ext }
                if let match = candidates.compactMap({ other -> (URL, Double)? in
                    guard let otherVector = other.0.vector, vector.count == otherVector.count, !vector.isEmpty,
                          vector.allSatisfy(\.isFinite), otherVector.allSatisfy(\.isFinite) else { return nil }
                    guard similarityComparisons < 100_000 else { plan.limited = true; return nil }
                    similarityComparisons += 1
                    let score = VectorMath.cosine(vector, otherVector)
                    return score >= 0.94 ? (other.0.url, score) : nil
                }).max(by: { $0.1 < $1.1 }) {
                    kind = .related; related = match.0; plan.usesEmbeddings = true
                    evidence = "Local content embeddings are similar (\(String(format: "%.2f", match.1))) to a newer document. This may be a distinct document or valuable draft; compare both before deciding."
                }
            }
            guard let kind else { continue }
            guard plan.suggestions.count < 100 else { plan.limited = true; continue }
            guard hashedBytes + stamp.size <= hashBudget else { plan.limited = true; continue }
            hashedBytes += stamp.size
            guard let digest = try? checkedDigest(file.url, stamp: stamp, scope: scope, allowCache: true) else { continue }
            plan.suggestions.append(CleanupFile(id: UUID(), url: file.url, bytes: stamp.size, modified: stamp.modified, kind: kind, evidence: evidence, relatedURL: related, reviewScore: reviewScore, stamp: stamp, digest: digest))
        }
        if similarityComparisons >= 100_000 { plan.limited = true }
        plan.suggestions.sort {
            if $0.reviewScore != $1.reviewScore { return $0.reviewScore > $1.reviewScore }
            return $0.bytes == $1.bytes ? $0.url.path < $1.url.path : $0.bytes > $1.bytes
        }
        try Task.checkCancellation()
        review = plan
        return plan
    }
    public func apply(reviewID: UUID, selected: Set<UUID>, excluding protected: [URL] = []) throws -> CleanupResult {
        exclusions.append(contentsOf: protected.map(\.canonical))
        guard let plan = review, plan.id == reviewID else { throw OpenFilesError.message("This cleanup review has expired. Scan again.") }
        let known = Set(plan.files.map(\.id))
        guard !selected.isEmpty, selected.isSubset(of: known) else { throw OpenFilesError.message("Select files from the current review.") }
        for group in plan.duplicates {
            guard !group.files.allSatisfy({ selected.contains($0.id) }) else { throw OpenFilesError.message("Keep at least one copy of every duplicate group.") }
        }
        // Preflight the entire selection and each retained duplicate before moving anything.
        for file in plan.files where selected.contains(file.id) {
            try validateScreenshotUse(file)
            guard try checkedDigest(file.url, stamp: file.stamp, scope: plan.scope) == file.digest else { throw OpenFilesError.message("A selected file changed. Scan again before cleanup.") }
        }
        for group in plan.duplicates where group.files.contains(where: { selected.contains($0.id) }) {
            guard let keeper = group.files.first(where: { !selected.contains($0.id) }),
                  try checkedDigest(keeper.url, stamp: keeper.stamp, scope: plan.scope) == keeper.digest else { throw OpenFilesError.message("A retained duplicate changed or disappeared. Nothing was moved.") }
        }
        let journal = appData.appendingPathComponent("Cleanup", isDirectory: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let recordURL = journal.appendingPathComponent(plan.id.uuidString + ".json")
        var result = CleanupResult()
        try JSONEncoder().encode(result.receipts).write(to: recordURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
        review = nil // A review can only be executed once, including partially successful batches.
        for file in plan.files where selected.contains(file.id) {
            do {
                try Task.checkCancellation()
                // Recheck immediately before the OS Trash operation; never fall back to unlink/remove.
                try validateScreenshotUse(file)
                guard try checkedDigest(file.url, stamp: file.stamp, scope: plan.scope) == file.digest else { throw OpenFilesError.message("File changed after review") }
                if let group = plan.duplicates.first(where: { $0.files.contains(where: { $0.id == file.id }) }) {
                    guard let keeper = group.files.first(where: { !selected.contains($0.id) }),
                          try checkedDigest(keeper.url, stamp: keeper.stamp, scope: plan.scope) == keeper.digest else { throw OpenFilesError.message("Retained copy changed") }
                }
                try Task.checkCancellation()
                let trashed = try trash.moveToTrash(file.url)
                result.receipts.append(CleanupReceipt(id: UUID(), original: file.url, trashed: trashed, date: Date()))
                do {
                    try JSONEncoder().encode(result.receipts).write(to: recordURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
                }
                catch { result.errors.append("Moved to Trash, but could not save receipt: \(file.url.path)"); break }
            } catch { result.errors.append("\(file.url.lastPathComponent): \(error.localizedDescription)") }
        }
        return result
    }
    private func safeStamp(_ url: URL, scope: URL) throws -> FileStamp {
        guard scanRoots.contains(where: { syncContains($0, url) }), hasExpectedCanonicalPath(url),
              !syncContains(appData, url), !exclusions.contains(where: { syncContains($0, url) }) else { throw OpenFilesError.message("Excluded or redirected path") }
        var folderProtection: [String: Bool] = [:]
        guard SemanticOrganizer.exclusion(url, roots: scanRoots, output: appData, appData: appData, excluded: exclusions, folderProtection: &folderProtection) == nil else { throw OpenFilesError.message("App, project or protected file") }
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else { throw OpenFilesError.message("Only regular files with no hard links are eligible") }
        let resources = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard resources.isUbiquitousItem != true else { throw OpenFilesError.message("Cloud-synced files are excluded from cleanup") }
        return try FileStamp.read(url)
    }
    private func validateScreenshotUse(_ file: CleanupFile) throws {
        guard file.kind == .screenshot else { return }
        let metadata = screenshotMetadata.metadata(for: file.url)
        if !metadata.tags.isEmpty || (metadata.lastUsed.map { $0 > Date().addingTimeInterval(-60 * 86400) } ?? false) {
            throw OpenFilesError.message("This screenshot was opened recently or tagged to keep. Review it again.")
        }
    }
    private func checkedDigest(_ url: URL, stamp: FileStamp, scope: URL, allowCache: Bool = false) throws -> String {
        guard try safeStamp(url, scope: scope) == stamp else { throw OpenFilesError.message("File changed since review") }
        if allowCache, let cached = digestCache[url.path], cached.0 == stamp { return cached.1 }
        let digest = try FileIntegrity.digest(url)
        guard try safeStamp(url, scope: scope) == stamp else { throw OpenFilesError.message("File changed during verification") }
        if digestCache.count > 10_000 { digestCache.removeAll() }
        digestCache[url.path] = (stamp, digest)
        return digest
    }
}
