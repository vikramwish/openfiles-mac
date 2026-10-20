import Foundation

public struct CloudPreview: Identifiable, Sendable {
    public let id: UUID
    public let item: CloudItem
    public let url: URL
}

public enum CloudPreviewPolicy {
    public static let maximumBytes: Int64 = 25 * 1024 * 1024
    public static let extensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "webp", "txt", "md", "csv", "json", "rtf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "odt", "ods", "odp"]
    public static func supports(_ item: CloudItem) -> Bool {
        item.canDownload && !item.isFolder && extensions.contains((item.name as NSString).pathExtension.lowercased())
    }
    static func checkSize(_ size: Int64?) throws {
        guard let size, size >= 0, size <= maximumBytes else {
            throw CloudSyncError.message("Preview and comparison require a known file size of at most 25 MB. Save a copy to inspect this file.")
        }
    }
    static func checkFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CloudError.unsafeURL }
        try checkSize(values.fileSize.map(Int64.init))
    }
    static func suffix(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && ext.count <= 12 && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? "." + ext : ".bin"
    }
}

/// A session owns private, disposable copies. No filename becomes a path and no preview enters the index.
public actor CloudPreviewStore {
    private let directory: URL
    private var files: [UUID: URL] = [:]
    private var generation = UUID()
    public init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesPreviews-\(UUID())")) {
        self.directory = directory
    }
    public func prepare(_ item: CloudItem, remote: any CloudSyncRemote) async throws -> CloudPreview {
        let current = generation, id = UUID(), fm = FileManager.default
        let latest = try await remote.metadata(id: item.id)
        guard CloudPreviewPolicy.supports(latest) else { throw CloudError.unsupportedDownload }
        try CloudPreviewPolicy.checkSize(latest.size)
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
        let folder = directory.appendingPathComponent(id.uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var retained = false
        defer { if !retained { try? fm.removeItem(at: folder) } }
        let url = folder.appendingPathComponent("Preview" + CloudPreviewPolicy.suffix(latest.name))
        try await remote.download(latest, to: url)
        try CloudPreviewPolicy.checkFile(url)
        let after = try await remote.metadata(id: latest.id)
        guard after == latest else { throw CloudError.conflict("The cloud file changed while its preview was loading. Try again.") }
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        files[id] = folder; retained = true
        return CloudPreview(id: id, item: latest, url: url)
    }
    public func discard(_ id: UUID) { if let folder = files.removeValue(forKey: id) { try? FileManager.default.removeItem(at: folder) } }
    public func clear() {
        generation = UUID()
        for folder in files.values { try? FileManager.default.removeItem(at: folder) }
        files.removeAll()
    }
}
