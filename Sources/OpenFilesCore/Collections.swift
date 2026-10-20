import Foundation
import Darwin

/// A virtual collection stores paths only; membership never changes the source filesystem.
public struct FileCollection: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var files: [URL]
    public var updated: Date
    public init(id: UUID = UUID(), title: String, files: [URL] = [], updated: Date = Date()) {
        self.id = id; self.title = title; self.files = files; self.updated = updated
    }
}

/// Serializes mutations across windows and reloads before editing, so stale UI cannot replace membership.
public actor CollectionStore {
    private let directory: URL
    public init(directory: URL) { self.directory = directory.standardizedFileURL }

    public func load() throws -> [FileCollection] {
        let url = directory.appendingPathComponent("collections.json")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return [] }
        guard fd >= 0 else { throw failure("Could not read collections") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw OpenFilesError.message("Collection metadata must be a regular file.")
        }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        let collections = try JSONDecoder().decode([FileCollection].self, from: data)
        guard Set(collections.map(\.id)).count == collections.count else {
            throw OpenFilesError.message("Collection metadata contains duplicate identifiers.")
        }
        for collection in collections {
            _ = try title(collection.title)
            guard collection.files.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }),
                  Set(collection.files).count == collection.files.count else {
                throw OpenFilesError.message("Collection metadata contains invalid file references.")
            }
        }
        return collections.sorted { $0.updated > $1.updated }
    }

    @discardableResult public func create(title text: String, files: [URL] = []) throws -> FileCollection {
        var collections = try load()
        let collection = FileCollection(title: try title(text), files: try references(files))
        collections.insert(collection, at: 0)
        try persist(collections)
        return collection
    }
    public func rename(_ id: UUID, title text: String) throws {
        let name = try title(text)
        try edit(id) { $0.title = name }
    }
    public func add(_ urls: [URL], to id: UUID) throws {
        let additions = try references(urls)
        try edit(id) { collection in
            for url in additions where !collection.files.contains(url) { collection.files.append(url) }
        }
    }
    public func remove(_ url: URL, from id: UUID) throws {
        try edit(id) { $0.files.removeAll { $0 == url.standardizedFileURL } }
    }
    public func replace(_ old: URL, with url: URL, in id: UUID) throws {
        let replacements = try references([url])
        try edit(id) { collection in
            guard let index = collection.files.firstIndex(of: old) else {
                throw OpenFilesError.message("This reference was removed. Reopen the collection.")
            }
            if collection.files.contains(replacements[0]) { collection.files.remove(at: index) }
            else { collection.files[index] = replacements[0] }
        }
    }
    public func delete(_ id: UUID) throws {
        var collections = try load()
        collections.removeAll { $0.id == id }
        try persist(collections)
    }
    private func edit(_ id: UUID, change: (inout FileCollection) throws -> Void) throws {
        var collections = try load()
        guard let index = collections.firstIndex(where: { $0.id == id }) else {
            throw OpenFilesError.message("This collection was removed. Choose another collection.")
        }
        try change(&collections[index]); collections[index].updated = Date()
        try persist(collections)
    }
    private func title(_ text: String) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw OpenFilesError.message("Enter a collection name of 1–120 characters without line breaks.")
        }
        return name
    }
    private func references(_ urls: [URL]) throws -> [URL] {
        var result: [URL] = []
        for url in urls {
            guard url.isFileURL, url.path.hasPrefix("/") else {
                throw OpenFilesError.message("Collections support local file references. Save cloud files locally first.")
            }
            let normalized = url.standardizedFileURL
            // Metadata only: adding a placeholder never downloads its contents.
            let values = try normalized.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard values.isRegularFile == true || values.isDirectory == true else {
                throw OpenFilesError.message("Choose an accessible file or folder.")
            }
            if !result.contains(normalized) { result.append(normalized) }
        }
        return result
    }
    private func persist(_ collections: [FileCollection]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw failure("Could not open collection storage") }
        defer { close(folder) }
        let temporary = ".\(UUID().uuidString).tmp"
        let fd = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw failure("Could not save collections") }
        defer { close(fd); unlinkat(folder, temporary, 0) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(collections)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw failure("Could not write collections") }
                offset += written
            }
        }
        guard fsync(fd) == 0, renameat(folder, temporary, folder, "collections.json") == 0 else {
            throw failure("Could not finish saving collections")
        }
    }
    private func failure(_ action: String) -> OpenFilesError {
        .message("\(action): \(String(cString: strerror(errno))).")
    }
}
