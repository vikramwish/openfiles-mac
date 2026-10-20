import Foundation

/// Small atomic delta files form a write-ahead journal between full manifest saves.
/// Checkpoints never rewrite the complete corpus. A successful manifest save compacts it.
struct IndexCheckpointStore {
    private struct Batch: Codable {
        var version = 1
        let records: [FileRecord]
        let progress: IndexProgress
    }
    private let folder: URL
    private var sequence: UInt64 = 0
    init(directory: URL) { folder = directory.appendingPathComponent("IndexCheckpoints", isDirectory: true) }
    mutating func replay(into state: inout LibraryState) throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let batches = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var files = Dictionary(state.files.map { ($0.url.path, $0) }, uniquingKeysWith: { _, new in new })
        for path in batches {
            let batch = try JSONDecoder().decode(Batch.self, from: Data(contentsOf: path))
            guard batch.version == 1 else { throw OpenFilesError.message("Unsupported index checkpoint version.") }
            for record in batch.records { files[record.url.path] = record }
            state.lastIndexReport = batch.progress
            sequence = max(sequence, UInt64(path.deletingPathExtension().lastPathComponent) ?? 0)
        }
        let exclusions = state.indexSettings?.excludedFolders ?? []
        state.files = files.values.filter { file in !exclusions.contains { FileRules.contains($0, file.url) } }.sorted { $0.url.path < $1.url.path }
    }
    mutating func append(_ records: [FileRecord], progress: IndexProgress) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        sequence += 1
        let file = folder.appendingPathComponent(String(format: "%020llu.json", sequence))
        let data = try JSONEncoder().encode(Batch(records: records, progress: progress.persistedSummary))
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    mutating func compacted() throws {
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        sequence = 0
    }
}
