import Foundation
import CryptoKit

public struct PhotoResourceFingerprint: Hashable, Sendable {
    public let kind: String
    public let digest: String
    public let bytes: Int64
    public init(kind: String, digest: String, bytes: Int64) { self.kind = kind; self.digest = digest; self.bytes = bytes }
}

public struct PhotoFingerprint: Sendable {
    public let id: String
    public let resources: [PhotoResourceFingerprint]
    public init(id: String, resources: [PhotoResourceFingerprint]) { self.id = id; self.resources = resources }
    public var bytes: Int64 { resources.reduce(0) { $0 + $1.bytes } }
    // Include every resource: edits, RAW companions, and Live Photo video must agree too.
    public var signature: String? {
        guard !resources.isEmpty, resources.allSatisfy({ !$0.digest.isEmpty && $0.bytes > 0 }) else { return nil }
        let parts = resources.map { "\($0.kind.utf8.count):\($0.kind):\($0.bytes):\($0.digest)" }.sorted()
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct PhotoDuplicateGroup: Identifiable, Sendable {
    public let id: String
    public let items: [PhotoFingerprint]
    public var possibleSavings: Int64 { items.dropFirst().reduce(0) { $0 + $1.bytes } }
}

public enum PhotoDuplicates {
    public static func groups(_ fingerprints: [PhotoFingerprint]) -> [PhotoDuplicateGroup] {
        let unique = Dictionary(fingerprints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        return Dictionary(grouping: unique.filter { $0.signature != nil }, by: { $0.signature! })
            .filter { $0.value.count > 1 }
            .map { PhotoDuplicateGroup(id: $0.key, items: $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.id < $1.id }
    }
    /// Revalidate every affected group, including the copies that will remain.
    public static func validateRecheck(_ selected: Set<String>, in groups: [PhotoDuplicateGroup], current: [PhotoFingerprint]) throws {
        try validate(selected, in: groups)
        let affected = groups.filter { group in group.items.contains { selected.contains($0.id) } }.flatMap(\.items)
        let fresh = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard Set(fresh.keys) == Set(affected.map(\.id)), affected.allSatisfy({ item in
            item.signature != nil && fresh[item.id]?.signature == item.signature
        }) else { throw OpenFilesError.message("A selected photo or its retained copy changed. Review duplicates again.") }
    }
    /// A cleanup request must name reviewed items and retain one member of each group.
    public static func validate(_ selected: Set<String>, in groups: [PhotoDuplicateGroup]) throws {
        let known = Set(groups.flatMap { $0.items.map(\.id) })
        guard !selected.isEmpty, selected.isSubset(of: known) else { throw OpenFilesError.message("Choose photos from the duplicate review first.") }
        guard groups.allSatisfy({ !$0.items.allSatisfy { selected.contains($0.id) } }) else {
            throw OpenFilesError.message("Keep at least one photo in every duplicate group.")
        }
    }
}

public struct ArchivePhoto: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let stamp: FileStamp
}
public struct PhotoArchiveReview: Sendable {
    public let library: URL
    public let photos: [ArchivePhoto]
    public let groups: [PhotoDuplicateGroup]
    public let skipped: Int
}

/// Read-only inspection of locally stored originals. Never reads or edits Photos databases.
public enum PhotoArchive {
    public static func review(_ library: URL, progress: @Sendable (Int) async -> Void = { _ in }) async throws -> PhotoArchiveReview {
        let library = library.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        guard library.pathExtension.lowercased() == "photoslibrary",
              try library.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true else {
            throw OpenFilesError.message("Choose a .photoslibrary library.")
        }
        let roots = ["originals", "Masters"].map { library.appendingPathComponent($0, isDirectory: true) }.filter { fm.fileExists(atPath: $0.path) }
        guard !roots.isEmpty else { throw OpenFilesError.message("This library has no readable local originals. Connect the System Photo Library to include items available through PhotoKit.") }
        var photos: [ArchivePhoto] = [], fingerprints: [PhotoFingerprint] = [], skipped = 0
        let allowed = NativeImageContent.extensions.union(["dng", "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2", "mov", "mp4", "m4v"])
        for root in roots {
            guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.standardizedFileURL.path else { throw OpenFilesError.message("Linked original folders are not inspected.") }
            var enumerationError: Error?
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey], options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }) else {
                throw OpenFilesError.message("The originals folder could not be read.")
            }
            while let url = walker.nextObject() as? URL {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
                if values.isSymbolicLink == true { skipped += 1; walker.skipDescendants(); continue }
                if values.isDirectory == true { continue }
                guard values.isRegularFile == true, allowed.contains(url.pathExtension.lowercased()),
                      FileRules.contains(library, url.resolvingSymlinksInPath()) else { skipped += 1; continue }
                do {
                    let stamp = try FileStamp.read(url)
                    let digest = try FileIntegrity.digest(url)
                    guard try FileStamp.read(url) == stamp else { skipped += 1; continue }
                    photos.append(ArchivePhoto(url: url, stamp: stamp))
                    fingerprints.append(PhotoFingerprint(id: url.path, resources: [.init(kind: "original", digest: digest, bytes: stamp.size)]))
                    await progress(photos.count)
                } catch is CancellationError { throw CancellationError() }
                catch { skipped += 1 }
            }
            if let enumerationError { throw enumerationError }
        }
        try Task.checkCancellation()
        return PhotoArchiveReview(library: library, photos: photos.sorted { $0.url.path < $1.url.path }, groups: PhotoDuplicates.groups(fingerprints), skipped: skipped)
    }
}

public enum PhotoMediaAnalysis {
    public static func terms(at url: URL) throws -> [String] {
        let size = try FileStamp.read(url).size
        let result = try NativeImageContent.extract(url, size: size)
        guard let content = result.imageContent else { return [] }
        return Array(content.subjectTerms.union(content.textTerms).union(content.location?.searchKeys ?? [])).sorted()
    }
    public static func placeTerms(latitude: Double, longitude: Double) -> [String] {
        Array(PhotoLocation(latitude: latitude, longitude: longitude, names: []).searchKeys).sorted()
    }
}
