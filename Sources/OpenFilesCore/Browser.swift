import Foundation

public struct BrowserItem: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let isFolder: Bool
    public let isPackage: Bool
    public let size: Int64
    public let modified: Date
    public var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
    public var kind: String { url.canonical.pathExtension.lowercased() == "photoslibrary" ? "Photos Library" : isFolder ? "Folder" : isPackage ? "Project" : FileRules.category(url) }
    public var sensitive: Bool { FileRules.sensitive(name) }
    public init(url: URL, isFolder: Bool, isPackage: Bool, size: Int64, modified: Date) {
        self.url = url; self.isFolder = isFolder; self.isPackage = isPackage; self.size = size; self.modified = modified
    }
}

/// Browsing is independent of the semantic index. Every accessible folder is navigable.
/// Running on its own actor keeps directory navigation responsive during embedding work.
public actor FileBrowser {
    private let fm = FileManager.default
    public init() {}
    public func item(at url: URL) throws -> BrowserItem {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        let target = values.isSymbolicLink == true ? try url.canonical.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) : values
        let package = target.isPackage == true || FileRules.packageExtensions.contains(url.pathExtension.lowercased())
        return BrowserItem(url: url, isFolder: target.isDirectory == true && !package, isPackage: package, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
    }
    public func contents(of folder: URL, showHidden: Bool = false) throws -> [BrowserItem] {
        guard try folder.canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw OpenFilesError.message("This location is not a folder.") }
        let urls = try fm.contentsOfDirectory(at: folder.canonical, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey], options: showHidden ? [] : [.skipsHiddenFiles])
        // Metadata failures for one entry must not hide the rest of the folder.
        return urls.compactMap { try? item(at: $0) }.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    public func items(at urls: [URL]) -> [BrowserItem] { urls.compactMap { try? item(at: $0) } }
    public func createFolder(in parent: URL, name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw OpenFilesError.message("Enter a folder name without slashes.") }
        let target = parent.appendingPathComponent(name, isDirectory: true)
        guard !fm.fileExists(atPath: target.path) else { throw OpenFilesError.message("An item with that name already exists.") }
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }
}
