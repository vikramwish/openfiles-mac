import Foundation

public struct CloudSyncPair: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let provider: CloudProvider
    public let accountID: String
    public let localRoot: URL
    public let remoteFolderID: String
    public let remoteFolderName: String
}

public struct CloudSyncAction: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case upload = "Upload new file", updateRemote = "Upload changed file"
        case download = "Download new file", updateLocal = "Download changed file"
        case createLocalFolder = "Create local folder", createRemoteFolder = "Create cloud folder"
        case compare = "Compare existing copies", conflict = "Conflict"
        case unchanged = "Unchanged", rememberDirectory = "Paired folder"
    }
    public var id: String { path }
    public let path: String
    public let kind: Kind
    public let detail: String
    public let localDigest: String?
    public let remote: CloudItem?
}

public struct CloudSyncPlan: Sendable {
    public let pair: CloudSyncPair
    public let actions: [CloudSyncAction]
    let revision: Int
    public var changes: [CloudSyncAction] { actions.filter { $0.kind != .unchanged && $0.kind != .rememberDirectory } }
}

public struct CloudSyncReport: Sendable {
    public var transferred = 0
    public var conflicts: [String] = []
    public var backups: [URL] = []
    public init() {}
}

public enum CloudSyncError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// Reconciliation is separate from browsing, indexing, and organization. The app
/// supplies a streaming SHA-256 implementation; tests use exact fixture contents.
public actor CloudSyncEngine {
    private let directory: URL
    private let digest: @Sendable (URL) throws -> String
    private let fm = FileManager.default
    private var running = false

    public init(directory: URL, digest: @escaping @Sendable (URL) throws -> String) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.digest = digest
    }

    public func pairs() throws -> [CloudSyncPair] {
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { url in
                let state = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: url))
                guard state.schema == 1 else { throw CloudSyncError.message("This sync state needs a newer version of OpenFiles.") }
                return state.pair
            }.sorted { $0.provider.rawValue < $1.provider.rawValue }
    }

    public func pair(localRoot: URL, remoteFolderID: String?, remoteFolderName: String,
                     provider: CloudProvider, remote: any CloudSyncRemote) async throws -> CloudSyncPair {
        try begin(); defer { running = false }
        let values = try localRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let root = localRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard localRoot.isFileURL, values.isDirectory == true, values.isSymbolicLink != true, root.path != "/",
              !contains(root, directory), !contains(directory, root) else {
            throw CloudSyncError.message("Choose a normal folder outside OpenFiles application data.")
        }
        let existing = try pairs()
        guard !existing.contains(where: { $0.provider == provider || contains($0.localRoot, root) || contains(root, $0.localRoot) }) else {
            throw CloudSyncError.message("Remove the existing pairing first. Sync folders must not overlap; one pairing per provider is supported.")
        }
        let account = try await remote.identity()
        let folder = try await remote.metadata(id: remoteFolderID ?? "root")
        guard folder.isFolder else { throw CloudSyncError.message("The selected remote location is not a folder.") }
        try Task.checkCancellation()
        let pair = CloudSyncPair(id: UUID(), provider: provider, accountID: account, localRoot: root,
                                 remoteFolderID: folder.id, remoteFolderName: remoteFolderName)
        try save(SyncState(pair: pair))
        return pair
    }

    public func removePair(_ pair: CloudSyncPair) throws {
        try begin(); defer { running = false }
        try fm.removeItem(at: stateURL(pair))
        // Downloaded files, cloud files, and retained backups remain untouched.
    }

    public func preview(_ pair: CloudSyncPair, remote: any CloudSyncRemote) async throws -> CloudSyncPlan {
        try begin(); defer { running = false }
        let state = try load(pair)
        try await validate(pair, remote: remote)
        let local = try localInventory(pair.localRoot)
        let cloud = try await remoteInventory(pair.remoteFolderID, remote: remote)
        let paths = Set(local.keys).union(cloud.keys).union(state.files.keys).union(state.folders.keys)
        var spellings: [String: String] = [:]
        for path in paths {
            let key = nameKey(path)
            if let other = spellings[key], other != path { throw CloudSyncError.message("Case-colliding paths: \(other) and \(path). Rename one before syncing.") }
            spellings[key] = path
        }
        var actions: [CloudSyncAction] = []
        for path in paths.sorted(by: pathOrder) {
            let left = local[path], right = cloud[path], base = state.files[path]
            var kind: CloudSyncAction.Kind = .unchanged
            var detail = ""
            if let left, !left.supported {
                kind = .conflict; detail = "Symbolic links and special files are excluded."
            } else if let right, !right.isFolder && (!right.canDownload || right.revision == nil) {
                kind = .conflict; detail = "This cloud item does not support file-content sync or has no revision."
            } else if let left, let right, left.folder != right.isFolder {
                kind = .conflict; detail = "A file and folder have the same path."
            } else if base != nil && (left?.folder == true || right?.isFolder == true) {
                kind = .conflict; detail = "A previously synced file was replaced by a folder."
            } else if state.folders[path] != nil && left?.folder != true && right?.isFolder != true && (left != nil || right != nil) {
                kind = .conflict; detail = "A previously paired folder was replaced by a file."
            } else if left?.folder == true || right?.isFolder == true {
                if let oldID = state.folders[path], right?.id != oldID || left == nil {
                    kind = .conflict; detail = "A paired folder was removed or replaced. Deletions and renames require manual resolution."
                } else if left == nil { kind = .createLocalFolder }
                else if right == nil { kind = .createRemoteFolder }
                else { kind = .rememberDirectory }
            } else if left == nil && right == nil {
                continue
            } else if let base {
                if left == nil || right == nil {
                    kind = .conflict; detail = "A previously synced file is missing on one side. Deletions are not propagated or restored automatically."
                } else if right!.id != base.remoteID {
                    kind = .conflict; detail = "The remote file was replaced by another item."
                } else {
                    let localChanged = left!.digest != base.digest, remoteChanged = right!.revision != base.remoteRevision
                    if localChanged && remoteChanged { kind = .compare; detail = "Both copies changed; identical content can converge, otherwise this is a conflict." }
                    else if localChanged { kind = .updateRemote }
                    else if remoteChanged { kind = .updateLocal }
                }
            } else if left == nil { kind = .download }
            else if right == nil { kind = .upload }
            else { kind = .compare; detail = "No common baseline yet. Only identical content is accepted automatically." }
            actions.append(CloudSyncAction(path: path, kind: kind, detail: detail, localDigest: left?.digest, remote: right))
        }
        return CloudSyncPlan(pair: pair, actions: actions, revision: state.revision)
    }

    public func apply(_ plan: CloudSyncPlan, remote: any CloudSyncRemote) async throws -> CloudSyncReport {
        try begin(); defer { running = false }
        let pair = plan.pair
        var state = try load(pair)
        guard state.revision == plan.revision else { throw CloudSyncError.message("This preview is stale. Preview sync again.") }
        try await validate(pair, remote: remote)
        var report = CloudSyncReport(), blocked = Set<String>()
        var directories = Dictionary(uniqueKeysWithValues: plan.actions.compactMap { action -> (String, String)? in
            guard let item = action.remote, item.isFolder else { return nil }; return (action.path, item.id)
        })
        directories[""] = pair.remoteFolderID
        for action in plan.actions {
            try Task.checkCancellation()
            if blocked.contains(where: { action.path.hasPrefix($0 + "/") }) {
                report.conflicts.append("\(action.path): its parent folder has an unresolved conflict."); continue
            }
            if action.kind == .conflict {
                report.conflicts.append("\(action.path): \(action.detail)"); blocked.insert(action.path); continue
            }
            do {
                try await validate(pair, remote: remote)
                let target = try localURL(action.path, root: pair.localRoot)
                let parentPath = (action.path as NSString).deletingLastPathComponent
                guard let parentID = directories[parentPath] else { throw CloudSyncError.message("The remote parent folder is unavailable.") }
                try await validateRemoteParent(parentPath, directories: directories, rootID: pair.remoteFolderID, remote: remote)
                if let expected = action.remote {
                    guard try await children(parentID, remote: remote).contains(where: { $0.id == expected.id && $0.name == expected.name }) else {
                        throw CloudError.conflict("The remote item moved or was removed after the preview.")
                    }
                }
                switch action.kind {
                case .unchanged: continue
                case .rememberDirectory:
                    guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CloudError.sourceChanged }
                    state.folders[action.path] = action.remote!.id
                case .createLocalFolder:
                    let item = try await checkedRemote(action.remote!, remote: remote)
                    guard item.isFolder, !exists(target) else { throw CloudError.destinationExists }
                    try fm.createDirectory(at: target, withIntermediateDirectories: false)
                    state.folders[action.path] = item.id; report.transferred += 1
                case .createRemoteFolder:
                    guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CloudError.sourceChanged }
                    let item = try await remote.createFolder(name: target.lastPathComponent, parentID: parentID)
                    guard item.isFolder else { throw CloudError.invalidResponse }
                    directories[action.path] = item.id; state.folders[action.path] = item.id; report.transferred += 1
                case .upload, .updateRemote:
                    try checkLocal(target, expected: action.localDigest)
                    let scratch = try scratchDirectory(); defer { try? fm.removeItem(at: scratch) }
                    let snapshot = scratch.appendingPathComponent("source")
                    try fm.copyItem(at: target, to: snapshot)
                    guard try digest(snapshot) == action.localDigest else { throw CloudError.sourceChanged }
                    let replacing = action.kind == .updateRemote ? try await checkedRemote(action.remote!, remote: remote) : nil
                    let result = try await remote.upload(snapshot, folderID: parentID, name: target.lastPathComponent, replacing: replacing)
                    guard let revision = result.revision, result.name == target.lastPathComponent else { throw CloudError.invalidResponse }
                    state.files[action.path] = Baseline(digest: action.localDigest!, remoteID: result.id, remoteRevision: revision)
                    report.transferred += 1
                case .download, .updateLocal, .compare:
                    let expected = try await checkedRemote(action.remote!, remote: remote)
                    if action.kind == .download {
                        guard !exists(target) else { throw CloudError.destinationExists }
                    } else { try checkLocal(target, expected: action.localDigest) }
                    let scratch = try scratchDirectory(); defer { try? fm.removeItem(at: scratch) }
                    let incoming = scratch.appendingPathComponent("incoming")
                    try await remote.download(expected, to: incoming)
                    _ = try await checkedRemote(expected, remote: remote)
                    let incomingDigest = try digest(incoming)
                    if action.kind == .compare {
                        try checkLocal(target, expected: action.localDigest)
                        guard incomingDigest == action.localDigest else {
                            throw CloudError.conflict("Both copies differ. Keep the desired copy under a new name, or resolve both copies manually before syncing again.")
                        }
                    } else {
                        try Task.checkCancellation()
                        if let backup = try install(incoming, at: target, expected: action.localDigest, pair: pair, path: action.path) {
                            report.backups.append(backup)
                        }
                        report.transferred += 1
                    }
                    state.files[action.path] = Baseline(digest: incomingDigest, remoteID: expected.id, remoteRevision: expected.revision!)
                case .conflict: break
                }
                state.revision += 1
                try save(state)
            } catch is CancellationError { throw CancellationError() }
            catch {
                report.conflicts.append("\(action.path): \(error.localizedDescription)")
                blocked.insert(action.path)
            }
        }
        return report
    }

    private func checkedRemote(_ expected: CloudItem, remote: any CloudSyncRemote) async throws -> CloudItem {
        let latest = try await remote.metadata(id: expected.id)
        guard latest.id == expected.id, latest.name == expected.name, latest.isFolder == expected.isFolder,
              latest.isFolder || (latest.revision != nil && latest.revision == expected.revision) else {
            throw CloudError.conflict("The remote item changed after the preview. Preview again.")
        }
        return latest
    }

    private func children(_ id: String, remote: any CloudSyncRemote) async throws -> [CloudItem] {
        var result: [CloudItem] = [], next: String?, seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await remote.items(folderID: id, pageToken: next)
            result += page.items; next = page.nextPageToken
            guard result.count <= 10_000 else { throw CloudSyncError.message("Too many cloud entries to validate this folder.") }
            if let next, !seen.insert(next).inserted { throw CloudError.invalidResponse }
        } while next != nil
        return result
    }

    private func validateRemoteParent(_ path: String, directories: [String: String], rootID: String, remote: any CloudSyncRemote) async throws {
        var parentID = rootID, prefix = ""
        for part in path.split(separator: "/") {
            prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
            guard let id = directories[prefix], try await children(parentID, remote: remote).contains(where: {
                $0.id == id && $0.name == String(part) && $0.isFolder
            }) else { throw CloudError.conflict("A cloud parent folder moved after the preview.") }
            parentID = id
        }
    }

    private func validate(_ pair: CloudSyncPair, remote: any CloudSyncRemote) async throws {
        try Task.checkCancellation()
        guard pair.localRoot.resolvingSymlinksInPath().standardizedFileURL == pair.localRoot,
              try pair.localRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CloudSyncError.message("The paired local folder is missing or has been replaced by a symbolic link.")
        }
        guard try await remote.identity() == pair.accountID else {
            throw CloudSyncError.message("This pairing belongs to a different account. Reconnect that account or remove and recreate the pairing.")
        }
        let root = try await remote.metadata(id: pair.remoteFolderID)
        guard root.isFolder else { throw CloudSyncError.message("The paired cloud folder is no longer available.") }
    }

    private func localInventory(_ root: URL) throws -> [String: LocalEntry] {
        var result: [String: LocalEntry] = [:]
        func walk(_ folder: URL, prefix: String, depth: Int) throws {
            guard depth <= 64, result.count < 10_000 else { throw CloudSyncError.message("Sync supports up to 10,000 entries and 64 folder levels per pairing.") }
            var names = Set<String>()
            for url in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                try Task.checkCancellation()
                try CloudClient.validateName(url.lastPathComponent)
                guard names.insert(nameKey(url.lastPathComponent)).inserted else { throw CloudSyncError.message("Ambiguous local filenames in \(prefix).") }
                let path = prefix + url.lastPathComponent
                let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                let supported = info.isSymbolicLink != true && (info.isDirectory == true || info.isRegularFile == true)
                result[path] = LocalEntry(folder: info.isDirectory == true, supported: supported,
                                          digest: supported && info.isRegularFile == true ? try digest(url) : nil)
                guard result.count <= 10_000 else { throw CloudSyncError.message("Sync supports up to 10,000 entries per pairing.") }
                if supported && info.isDirectory == true { try walk(url, prefix: path + "/", depth: depth + 1) }
            }
        }
        try walk(root, prefix: "", depth: 0)
        return result
    }

    private func remoteInventory(_ rootID: String, remote: any CloudSyncRemote) async throws -> [String: CloudItem] {
        var result: [String: CloudItem] = [:], visited = Set<String>()
        var queue: [(String, String, Int)] = [(rootID, "", 0)]
        while !queue.isEmpty {
            let (id, prefix, depth) = queue.removeFirst()
            guard visited.insert(id).inserted, depth <= 64 else { throw CloudSyncError.message("The cloud folder tree contains a repeated folder or too many levels.") }
            var next: String?, pages = Set<String>(), names = Set<String>()
            repeat {
                try Task.checkCancellation()
                let page = try await remote.items(folderID: id, pageToken: next)
                for item in page.items {
                    try CloudClient.validateName(item.name)
                    if item.name.hasPrefix(".") { continue }
                    guard names.insert(nameKey(item.name)).inserted else { throw CloudSyncError.message("Duplicate or case-colliding cloud names in \(prefix). Resolve them before syncing.") }
                    let path = prefix + item.name
                    result[path] = item
                    guard result.count <= 10_000 else { throw CloudSyncError.message("Sync supports up to 10,000 entries per pairing.") }
                    if item.isFolder { queue.append((item.id, path + "/", depth + 1)) }
                }
                next = page.nextPageToken
                if let next, !pages.insert(next).inserted { throw CloudError.invalidResponse }
            } while next != nil
        }
        return result
    }

    private func checkLocal(_ url: URL, expected: String?) throws {
        let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard let expected, info.isSymbolicLink != true, info.isRegularFile == true, try digest(url) == expected else {
            throw CloudError.sourceChanged
        }
    }

    private func install(_ incoming: URL, at target: URL, expected: String?, pair: CloudSyncPair, path: String) throws -> URL? {
        _ = try localURL(path, root: pair.localRoot)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".openfiles-sync-\(UUID())")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: incoming, to: staging)
        guard try digest(staging) == digest(incoming) else { throw CloudError.sourceChanged }
        var backup: URL?
        var previous: URL?
        if let expected {
            try checkLocal(target, expected: expected)
            let folder = directory.appendingPathComponent("Backups/\(pair.id)/\(UUID())")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let saved = folder.appendingPathComponent(target.lastPathComponent)
            // The backup may live on a different volume. Verify a copy before
            // moving the original aside on its own volume for final publication.
            do {
                try fm.copyItem(at: target, to: saved)
                try checkLocal(saved, expected: expected)
            } catch {
                try? fm.removeItem(at: folder)
                throw error
            }
            try checkLocal(target, expected: expected)
            if let mode = try fm.attributesOfItem(atPath: target.path)[.posixPermissions] {
                try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: staging.path)
            }
            let sibling = target.deletingLastPathComponent().appendingPathComponent(".openfiles-previous-\(UUID())")
            try fm.moveItem(at: target, to: sibling)
            previous = sibling
            backup = saved
        }
        do {
            if let previous, let expected { try checkLocal(previous, expected: expected) }
            guard !exists(target) else { throw CloudError.destinationExists }
            try fm.moveItem(at: staging, to: target)
            if let previous, let expected {
                try checkLocal(previous, expected: expected)
                try fm.removeItem(at: previous)
            }
        } catch {
            if let previous {
                if !exists(target) { try? fm.moveItem(at: previous, to: target) }
                if exists(previous) {
                    throw CloudSyncError.message("Local content was retained at \(previous.path). Review it before syncing again. \(error.localizedDescription)")
                }
            }
            throw error
        }
        return backup
    }

    private func localURL(_ path: String, root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        var url = root
        for part in parts {
            try CloudClient.validateName(String(part))
            guard !part.hasPrefix(".") else { throw CloudError.unsafeURL }
            url.appendPathComponent(String(part))
            if exists(url), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw CloudError.unsafeURL }
        }
        guard contains(root, url), url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else { throw CloudError.unsafeURL }
        return url
    }

    private func begin() throws {
        guard !running else { throw CloudSyncError.message("A sync operation is already running.") }; running = true
    }
    private func stateURL(_ pair: CloudSyncPair) -> URL { directory.appendingPathComponent("\(pair.id).json") }
    private func load(_ pair: CloudSyncPair) throws -> SyncState {
        let state = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: stateURL(pair)))
        guard state.schema == 1, state.pair == pair else { throw CloudSyncError.message("This pairing changed. Load it again before syncing.") }
        return state
    }
    private func save(_ state: SyncState) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: stateURL(state.pair), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL(state.pair).path)
    }
    private func scratchDirectory() throws -> URL {
        let url = directory.appendingPathComponent("Temporary/\(UUID())")
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return url
    }
    private func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
    private func contains(_ root: URL, _ child: URL) -> Bool { child.path == root.path || child.path.hasPrefix(root.path + "/") }
    private func nameKey(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    private func pathOrder(_ a: String, _ b: String) -> Bool {
        let left = a.split(separator: "/").count, right = b.split(separator: "/").count
        return left == right ? a < b : left < right
    }
}

private struct LocalEntry { let folder: Bool; let supported: Bool; let digest: String? }
private struct Baseline: Codable { let digest: String; let remoteID: String; let remoteRevision: String }
private struct SyncState: Codable {
    var schema = 1
    var revision = 0
    let pair: CloudSyncPair
    var files: [String: Baseline] = [:]
    var folders: [String: String] = [:]
}
