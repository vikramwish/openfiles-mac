import Foundation
import OpenFilesCloud

private struct SyncCheckFailure: Error, CustomStringConvertible {
    let description: String
}
private func verify(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw SyncCheckFailure(description: message) }
}
private func rejects(_ action: () async throws -> Void) async throws {
    do { try await action() } catch { return }
    throw SyncCheckFailure(description: "Expected operation to reject unsafe state")
}

private actor FakeDrive: CloudSyncRemote {
    struct Node { var name: String; var parent: String; var bytes: Data?; var version = 1 }
    private var nodes: [String: Node] = ["root": Node(name: "Root", parent: "", bytes: nil)]
    private var account = "fixture-account"
    private var downloadHook: (@Sendable () async throws -> Void)?
    func identity() async throws -> String { account }
    func setAccount(_ value: String) { account = value }
    func hookDownload(_ action: @escaping @Sendable () async throws -> Void) { downloadHook = action }
    func seed(_ name: String, parent: String = "root", text: String? = nil) -> CloudItem {
        let id = UUID().uuidString
        nodes[id] = Node(name: name, parent: parent, bytes: text.map { Data($0.utf8) })
        return item(id)
    }
    func edit(_ id: String, text: String) { nodes[id]!.bytes = Data(text.utf8); nodes[id]!.version += 1 }
    func move(_ id: String, to parent: String) { nodes[id]!.parent = parent; nodes[id]!.version += 1 }
    func remove(_ id: String) { nodes.removeValue(forKey: id) }
    func contents(_ id: String) -> String { String(data: nodes[id]!.bytes!, encoding: .utf8)! }
    func find(_ name: String, parent: String = "root") -> CloudItem? {
        nodes.first { $0.value.parent == parent && $0.value.name == name }.map { item($0.key) }
    }
    private func item(_ id: String) -> CloudItem {
        let node = nodes[id]!
        return CloudItem(id: id, name: node.name, isFolder: node.bytes == nil,
                         size: node.bytes.map { Int64($0.count) }, revision: String(node.version), etag: "\"\(node.version)\"")
    }
    func metadata(id: String) async throws -> CloudItem {
        guard nodes[id] != nil else { throw CloudError.notFound }; return item(id)
    }
    func items(folderID: String?, pageToken: String?) async throws -> CloudPage {
        let all = nodes.filter { $0.value.parent == (folderID ?? "root") }.keys.sorted().map { item($0) }
        let offset = Int(pageToken ?? "0")!
        return CloudPage(items: Array(all.dropFirst(offset).prefix(2)), nextPageToken: offset + 2 < all.count ? String(offset + 2) : nil)
    }
    func createFolder(name: String, parentID: String?) async throws -> CloudItem {
        guard find(name, parent: parentID ?? "root") == nil else { throw CloudError.destinationExists }
        return seed(name, parent: parentID ?? "root")
    }
    func upload(_ source: URL, folderID: String?, name: String, replacing: CloudItem?) async throws -> CloudItem {
        let data = try Data(contentsOf: source)
        if let replacing {
            guard let node = nodes[replacing.id], String(node.version) == replacing.revision else { throw CloudError.conflict("stale version") }
            nodes[replacing.id]!.bytes = data; nodes[replacing.id]!.version += 1
            return item(replacing.id)
        }
        guard find(name, parent: folderID ?? "root") == nil else { throw CloudError.destinationExists }
        let id = UUID().uuidString
        nodes[id] = Node(name: name, parent: folderID ?? "root", bytes: data)
        return item(id)
    }
    func download(_ item: CloudItem, to destination: URL) async throws {
        if let hook = downloadHook { downloadHook = nil; try await hook() }
        guard let data = nodes[item.id]?.bytes else { throw CloudError.notFound }
        try data.write(to: destination, options: .withoutOverwriting)
    }
}

private struct SyncFixture {
    let base: URL
    let local: URL
    let state: URL
    let engine: CloudSyncEngine
    let remote = FakeDrive()
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesSyncChecks-\(UUID())")
        local = base.appendingPathComponent("Local"); state = base.appendingPathComponent("State")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        engine = CloudSyncEngine(directory: state, digest: { try Data(contentsOf: $0).base64EncodedString() })
    }
    func write(_ name: String, _ contents: String) throws {
        let url = local.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    func read(_ name: String) throws -> String { try String(contentsOf: local.appendingPathComponent(name), encoding: .utf8) }
    func pair(folder: String? = nil) async throws -> CloudSyncPair {
        try await engine.pair(localRoot: local, remoteFolderID: folder, remoteFolderName: "Test cloud folder", provider: .googleDrive, remote: remote)
    }
    func sync(_ pair: CloudSyncPair) async throws -> CloudSyncReport {
        let plan = try await engine.preview(pair, remote: remote)
        return try await engine.apply(plan, remote: remote)
    }
    func clean() { try? FileManager.default.removeItem(at: base) }
}

private func recursiveSync() async throws {
    let f = try SyncFixture(); defer { f.clean() }
    try f.write("Local folder/a.txt", "local content")
    let folder = await f.remote.seed("Remote folder")
    _ = await f.remote.seed("b.txt", parent: folder.id, text: "remote content")
    let pair = try await f.pair(), report = try await f.sync(pair)
    try verify(report.conflicts.isEmpty && report.transferred == 4, "Recursive two-way transfers failed: \(report.conflicts)")
    try verify(try f.read("Remote folder/b.txt") == "remote content", "Remote file did not reach local subfolder")
    let uploadedFolder = await f.remote.find("Local folder")!
    let uploaded = await f.remote.find("a.txt", parent: uploadedFolder.id)!
    let bytes = await f.remote.contents(uploaded.id)
    try verify(bytes == "local content", "Local nested file was not uploaded")
    let reopened = CloudSyncEngine(directory: f.state, digest: { try Data(contentsOf: $0).base64EncodedString() })
    let pairs = try await reopened.pairs(), plan = try await reopened.preview(pair, remote: f.remote)
    try verify(pairs == [pair] && plan.changes.isEmpty, "Pairing/baseline was not retained across engine restart")
}

private func oneSidedEdits() async throws {
    let f = try SyncFixture(); defer { f.clean() }
    try f.write("file.txt", "original")
    let pair = try await f.pair(); _ = try await f.sync(pair)
    let item = await f.remote.find("file.txt")!
    try f.write("file.txt", "local update")
    let upload = try await f.sync(pair), remoteContent = await f.remote.contents(item.id)
    try verify(upload.conflicts.isEmpty && remoteContent == "local update", "Local-only edit did not update remote")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.local.appendingPathComponent("file.txt").path)
    await f.remote.edit(item.id, text: "remote update")
    let download = try await f.sync(pair)
    try verify(download.conflicts.isEmpty && download.backups.count == 1, "Remote-only update did not retain backup")
    try verify(try f.read("file.txt") == "remote update", "Remote edit did not update local")
    try verify(try String(contentsOf: download.backups[0]) == "local update", "Local previous content was lost")
    let mode = try FileManager.default.attributesOfItem(atPath: f.local.appendingPathComponent("file.txt").path)[.posixPermissions] as? Int
    try verify(mode == 0o600, "Sync broadened local file permissions")
}

private func divergedEdits() async throws {
    let f = try SyncFixture(); defer { f.clean() }
    try f.write("file.txt", "base")
    let pair = try await f.pair(); _ = try await f.sync(pair)
    let item = await f.remote.find("file.txt")!
    try f.write("file.txt", "local branch"); await f.remote.edit(item.id, text: "remote branch")
    let report = try await f.sync(pair), remoteContent = await f.remote.contents(item.id)
    try verify(report.conflicts.count == 1 && report.transferred == 0, "Concurrent edits must conflict")
    try verify(try f.read("file.txt") == "local branch" && remoteContent == "remote branch", "A conflicting copy was overwritten")
    let again = try await f.engine.preview(pair, remote: f.remote)
    try verify(again.changes.first?.kind == .compare, "Failed conflict advanced the baseline")
}

private func existingCopies() async throws {
    for identical in [false, true] {
        let f = try SyncFixture(); defer { f.clean() }
        try f.write("file.txt", "same")
        _ = await f.remote.seed("file.txt", text: identical ? "same" : "different")
        let pair = try await f.pair(), report = try await f.sync(pair)
        try verify(report.conflicts.count == (identical ? 0 : 1), "Initial comparison failed")
        let next = try await f.engine.preview(pair, remote: f.remote)
        try verify(identical ? next.changes.isEmpty : next.changes.count == 1, "Initial baseline was recorded incorrectly")
    }
}

private func deletionsStayManual() async throws {
    let f = try SyncFixture(); defer { f.clean() }
    try f.write("local-deleted.txt", "one"); try f.write("remote-deleted.txt", "two")
    let pair = try await f.pair(); _ = try await f.sync(pair)
    let first = await f.remote.find("local-deleted.txt")!, second = await f.remote.find("remote-deleted.txt")!
    try FileManager.default.removeItem(at: f.local.appendingPathComponent("local-deleted.txt"))
    await f.remote.remove(second.id)
    let report = try await f.sync(pair), kept = await f.remote.contents(first.id), absent = await f.remote.find("remote-deleted.txt")
    try verify(report.conflicts.count == 2 && report.transferred == 0, "Deletions must require manual resolution")
    try verify(!FileManager.default.fileExists(atPath: f.local.appendingPathComponent("local-deleted.txt").path), "Deleted local file was automatically restored")
    try verify(kept == "one" && absent == nil && (try f.read("remote-deleted.txt")) == "two", "A deletion propagated or resurrected a remote file")
}

private func stalePreview() async throws {
    let f = try SyncFixture(); defer { f.clean() }
    try f.write("file.txt", "previewed")
    let pair = try await f.pair(), plan = try await f.engine.preview(pair, remote: f.remote)
    try f.write("file.txt", "edited later")
    let report = try await f.engine.apply(plan, remote: f.remote), uploaded = await f.remote.find("file.txt")
    try verify(report.conflicts.count == 1 && uploaded == nil, "Stale local content uploaded")
    _ = try await f.sync(pair)
    let item = await f.remote.find("file.txt")!
    await f.remote.edit(item.id, text: "remote preview")
    let next = try await f.engine.preview(pair, remote: f.remote)
    await f.remote.edit(item.id, text: "remote edited later")
    let result = try await f.engine.apply(next, remote: f.remote)
    try verify(result.conflicts.count == 1 && (try f.read("file.txt")) == "edited later", "Stale remote version replaced local file")
}

private func localEditDuringDownload() async throws {
    let f = try SyncFixture(); defer { f.clean() }
    try f.write("file.txt", "baseline")
    let pair = try await f.pair(); _ = try await f.sync(pair)
    let item = await f.remote.find("file.txt")!
    await f.remote.edit(item.id, text: "remote update")
    let target = f.local.appendingPathComponent("file.txt")
    await f.remote.hookDownload { try Data("editor saved while downloading".utf8).write(to: target) }
    let report = try await f.sync(pair)
    try verify(report.conflicts.count == 1 && (try f.read("file.txt")) == "editor saved while downloading", "Editor changes were overwritten")
}

private func accountIsolation() async throws {
    let f = try SyncFixture(); defer { f.clean() }
    try f.write("private.txt", "local file")
    let pair = try await f.pair(), plan = try await f.engine.preview(pair, remote: f.remote)
    await f.remote.setAccount("another-account")
    try await rejects { _ = try await f.engine.apply(plan, remote: f.remote) }
    let remote = await f.remote.find("private.txt")
    try verify(remote == nil, "Pairing uploaded to the wrong account")
}

private func unsafeNamesAndLinks() async throws {
    let f = try SyncFixture(); defer { f.clean() }
    try f.write(".hidden", "hidden")
    let outside = f.base.appendingPathComponent("outside.txt")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: f.local.appendingPathComponent("link.txt"), withDestinationURL: outside)
    let pair = try await f.pair(), report = try await f.sync(pair)
    let hidden = await f.remote.find(".hidden"), link = await f.remote.find("link.txt")
    try verify(report.conflicts.count == 1 && hidden == nil && link == nil, "Hidden file or symlink escaped exclusions")
    _ = await f.remote.seed("../escape.txt", text: "bad")
    try await rejects { _ = try await f.engine.preview(pair, remote: f.remote) }
}

private func duplicateNames() async throws {
    for crossSide in [false, true] {
        let f = try SyncFixture(); defer { f.clean() }
        _ = await f.remote.seed("Report.txt", text: "one")
        if crossSide { try f.write("report.txt", "two") }
        else { _ = await f.remote.seed("report.txt", text: "two") }
        let pair = try await f.pair()
        try await rejects { _ = try await f.engine.preview(pair, remote: f.remote) }
    }
}

private func movedRemoteParent() async throws {
    let f = try SyncFixture(); defer { f.clean() }
    let paired = await f.remote.seed("Paired"), outside = await f.remote.seed("Outside")
    let child = await f.remote.seed("Nested", parent: paired.id)
    try f.write("Nested/file.txt", "data")
    let pair = try await f.pair(folder: paired.id), plan = try await f.engine.preview(pair, remote: f.remote)
    await f.remote.move(child.id, to: outside.id)
    let report = try await f.engine.apply(plan, remote: f.remote), escaped = await f.remote.find("file.txt", parent: child.id)
    try verify(!report.conflicts.isEmpty && escaped == nil, "Upload followed a folder moved outside the pairing")
}

private func localParentReplacedByLink() async throws {
    let f = try SyncFixture(); defer { f.clean() }
    let folder = await f.remote.seed("Folder")
    _ = await f.remote.seed("file.txt", parent: folder.id, text: "remote")
    try FileManager.default.createDirectory(at: f.local.appendingPathComponent("Folder"), withIntermediateDirectories: false)
    let pair = try await f.pair(), plan = try await f.engine.preview(pair, remote: f.remote)
    let outside = f.base.appendingPathComponent("Outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try FileManager.default.removeItem(at: f.local.appendingPathComponent("Folder"))
    try FileManager.default.createSymbolicLink(at: f.local.appendingPathComponent("Folder"), withDestinationURL: outside)
    let report = try await f.engine.apply(plan, remote: f.remote)
    try verify(!report.conflicts.isEmpty && (try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty, "Download escaped through a replaced parent")
}

private func failedTransferAndCancellation() async throws {
    let f = try SyncFixture(); defer { f.clean() }
    _ = await f.remote.seed("file.txt", text: "remote")
    let pair = try await f.pair()
    await f.remote.hookDownload { throw URLError(.networkConnectionLost) }
    let failed = try await f.sync(pair)
    try verify(failed.conflicts.count == 1 && !FileManager.default.fileExists(atPath: f.local.appendingPathComponent("file.txt").path), "Failed download published local content")
    let plan = try await f.engine.preview(pair, remote: f.remote)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await f.engine.apply(plan, remote: f.remote)
    }
    try await rejects { _ = try await task.value }
    let retried = try await f.sync(pair)
    try verify(retried.conflicts.isEmpty && (try f.read("file.txt")) == "remote", "Failed/cancelled transfer poisoned the next sync")
    try await f.engine.removePair(pair)
    let pairs = try await f.engine.pairs()
    try verify(pairs.isEmpty && (try f.read("file.txt")) == "remote", "Removing a pairing removed local data")
}

private func temporaryCloudPreviews() async throws {
    let f = try SyncFixture(); defer { f.clean() }
    let store = CloudPreviewStore(directory: f.base.appendingPathComponent("Previews"))
    let item = await f.remote.seed("../report.txt", text: "preview content")
    let result = try await store.prepare(item, remote: f.remote)
    try verify(result.url.lastPathComponent == "Preview.txt", "Remote filename became a local path")
    try verify(try String(contentsOf: result.url, encoding: .utf8) == "preview content", "Wrong preview contents")
    try verify(try FileManager.default.contentsOfDirectory(atPath: f.local.path).isEmpty, "Preview entered the paired folder")
    let mode = try FileManager.default.attributesOfItem(atPath: result.url.path)[.posixPermissions] as? NSNumber
    try verify(mode?.intValue == 0o400, "Preview must be read-only")
    await store.discard(result.id)
    try verify(!FileManager.default.fileExists(atPath: result.url.path), "Closed preview remained on disk")
    let next = try await store.prepare(item, remote: f.remote)
    await store.clear()
    try verify(!FileManager.default.fileExists(atPath: next.url.path), "Session cleanup retained preview content")
    let unsupported = await f.remote.seed("program.exe", text: "unsupported")
    try await rejects { _ = try await store.prepare(unsupported, remote: f.remote) }
}

private func staleAndCancelledPreviews() async throws {
    let f = try SyncFixture(); defer { f.clean() }
    let folder = f.base.appendingPathComponent("Previews"), store = CloudPreviewStore(directory: folder)
    let item = await f.remote.seed("report.txt", text: "old")
    await f.remote.hookDownload { await f.remote.edit(item.id, text: "new") }
    try await rejects { _ = try await store.prepare(item, remote: f.remote) }
    await f.remote.hookDownload { await store.clear() }
    try await rejects { _ = try await store.prepare(item, remote: f.remote) }
    await f.remote.hookDownload { throw CloudError.serviceUnavailable(503) }
    try await rejects { _ = try await store.prepare(item, remote: f.remote) }
    try verify(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "Failed previews retained content")
    let large = await f.remote.seed("large.pdf", text: String(repeating: "x", count: Int(CloudPreviewPolicy.maximumBytes) + 1))
    try await rejects { _ = try await store.prepare(large, remote: f.remote) }
}

private func compareAndResolveCopies() async throws {
    for keepLocal in [true, false] {
        let f = try SyncFixture(); defer { f.clean() }
        try f.write("report.txt", "shared\nlocal line")
        let remote = await f.remote.seed("report.txt", text: "shared\ncloud line")
        let pair = try await f.pair(), plan = try await f.engine.preview(pair, remote: f.remote)
        let comparison = try await f.engine.compare(plan, path: "report.txt", remote: f.remote)
        try verify(comparison.text?.changes.count == 2, "Expected removed and added text lines")
        try verify(try f.read("report.txt") == "shared\nlocal line", "Comparison changed the local file")
        let before = await f.remote.contents(remote.id); try verify(before == "shared\ncloud line", "Comparison changed the remote file")
        let report = try await f.engine.resolveComparison(comparison.id, choice: keepLocal ? .keepLocal : .keepCloud, remote: f.remote)
        let expected = keepLocal ? "shared\nlocal line" : "shared\ncloud line"
        let actualRemote = await f.remote.contents(remote.id)
        try verify(try f.read("report.txt") == expected && actualRemote == expected, "Choice did not converge both copies")
        try verify(report.backups.count == 1, "Replaced content was not backed up")
        let backup = try String(contentsOf: report.backups[0], encoding: .utf8)
        try verify(backup == (keepLocal ? "shared\ncloud line" : "shared\nlocal line"), "Wrong replaced copy backed up")
        let next = try await f.engine.preview(pair, remote: f.remote)
        try verify(next.changes.isEmpty, "Resolved conflict did not update the baseline")
        try verify(!FileManager.default.fileExists(atPath: comparison.cloudURL.path), "Consumed comparison retained temporary content")
        try await rejects { _ = try await f.engine.resolveComparison(comparison.id, choice: .keepCloud, remote: f.remote) }
    }
}

private func comparisonRevalidatesOriginals() async throws {
    for change in ["local", "remote", "account", "parent", "snapshot"] {
        let f = try SyncFixture(); defer { f.clean() }
        try f.write("report.txt", "local version")
        let item = await f.remote.seed("report.txt", text: "cloud version")
        let pair = try await f.pair(), plan = try await f.engine.preview(pair, remote: f.remote)
        let comparison = try await f.engine.compare(plan, path: "report.txt", remote: f.remote)
        switch change {
        case "local": try f.write("report.txt", "new local edit")
        case "remote": await f.remote.edit(item.id, text: "new cloud edit")
        case "account": await f.remote.setAccount("other-account")
        case "parent":
            let folder = await f.remote.seed("Elsewhere"); await f.remote.move(item.id, to: folder.id)
        default:
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: comparison.localURL.path)
            try Data("tampered snapshot".utf8).write(to: comparison.localURL)
        }
        try await rejects { _ = try await f.engine.resolveComparison(comparison.id, choice: .keepLocal, remote: f.remote) }
        let remoteText = await f.remote.contents(item.id)
        try verify(remoteText == (change == "remote" ? "new cloud edit" : "cloud version"), "A stale comparison overwrote remote content")
        try verify(try f.read("report.txt") == (change == "local" ? "new local edit" : "local version"), "A stale comparison overwrote local content")
    }
}

private func comparisonCleanupAndBinary() async throws {
    let f = try SyncFixture(); defer { f.clean() }
    try f.write("report.pdf", "binary\0local")
    _ = await f.remote.seed("report.pdf", text: "binary\0cloud")
    let pair = try await f.pair(), plan = try await f.engine.preview(pair, remote: f.remote)
    let comparison = try await f.engine.compare(plan, path: "report.pdf", remote: f.remote)
    try verify(comparison.text == nil, "Binary contents were presented as text differences")
    await f.engine.discardComparison(comparison.id)
    try verify(!FileManager.default.fileExists(atPath: comparison.localURL.path), "Closing comparison retained its snapshot")
    await f.remote.hookDownload { try f.write("report.pdf", "changed during comparison") }
    try await rejects { _ = try await f.engine.compare(plan, path: "report.pdf", remote: f.remote) }
    let temporary = f.state.appendingPathComponent("Temporary")
    try verify(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty, "Failed comparison leaked temporary copies")
}

let syncScenarios: [(String, () async throws -> Void)] = [
    ("Cloud previews use private temporary copies and clean up", temporaryCloudPreviews),
    ("Changed, cancelled, failed, and oversized previews are refused", staleAndCancelledPreviews),
    ("Conflict comparison resolves either choice with retained backups", compareAndResolveCopies),
    ("Conflict resolution revalidates original files, accounts, parents, and snapshots", comparisonRevalidatesOriginals),
    ("Binary comparison and cancelled review preserve files and clean up", comparisonCleanupAndBinary),
    ("Recursive two-way sync persists its baseline", recursiveSync),
    ("One-sided edits sync with retained local backups", oneSidedEdits),
    ("Divergent edits preserve both copies", divergedEdits),
    ("Existing copies require content agreement", existingCopies),
    ("Deletions remain manual on both sides", deletionsStayManual),
    ("Sync revalidates stale local and remote previews", stalePreview),
    ("Editor changes during download are retained", localEditDuringDownload),
    ("Sync pairings cannot cross accounts", accountIsolation),
    ("Sync excludes hidden files and symbolic links", unsafeNamesAndLinks),
    ("Sync refuses duplicate and case-colliding names", duplicateNames),
    ("Sync cannot follow a moved remote parent", movedRemoteParent),
    ("Sync cannot follow a replaced local parent", localParentReplacedByLink),
    ("Failed and cancelled syncs remain recoverable", failedTransferAndCancellation)
]
