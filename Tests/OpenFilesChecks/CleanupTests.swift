import Foundation
import OpenFilesCore

private struct TestCleanupTrash: CleanupTrash {
    let destination: URL
    func moveToTrash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let output = destination.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: output)
        return output
    }
}
private struct FailingCleanupTrash: CleanupTrash {
    func moveToTrash(_ url: URL) throws -> URL { throw OpenFilesError.message("Trash unavailable") }
}
struct CleanupChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Cleanup finds byte duplicates, preserves originals during review, and keeps a retained copy", duplicates),
        ("Cleanup rejects stale selections, changed keepers, links and protected locations", safeguards),
        ("Cleanup suggestions explain age and local semantic evidence without automatic selection", suggestions),
        ("Cleanup Trash errors preserve source files and never fall back to deletion", trashFailure)
    ]
    private static func fixture() throws -> (URL, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesCleanup-\(UUID())").resolvingSymlinksInPath()
        let scope = base.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        return (base, scope, base.appendingPathComponent("AppData"))
    }
    private static func record(_ url: URL, vector: [Double]? = nil, engine: String? = nil) throws -> FileRecord {
        let stamp = try FileStamp.read(url)
        let metadata = engine.map { FileIndexMetadata(stamp: stamp, engine: $0, objectKey: nil, wordUnits: 1, inputCharacters: 1, outcome: "test", detail: "test", retryable: false) }
        return FileRecord(id: UUID(), url: url, root: url.deletingLastPathComponent(), size: stamp.size, modified: stamp.modified, isProject: false, sensitive: false, vector: vector, indexMetadata: metadata)
    }
    private static func write(_ name: String, in scope: URL, text: String = "same document bytes") throws -> URL {
        let url = scope.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
    private static func rejects(_ operation: () async throws -> Void) async {
        do { try await operation(); failCheck("Expected cleanup to reject the action") } catch {}
    }
    static func duplicates() async throws {
        let (base, scope, data) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let a = try write("Original.txt", in: scope), b = try write("Copy.txt", in: scope)
        let different = try write("Different.txt", in: scope, text: "DIFF document bytes")
        let bytes = try Data(contentsOf: a), stamp = try FileStamp.read(a)
        let service = CleanupService(directory: data, trash: TestCleanupTrash(destination: base.appendingPathComponent("TestTrash")))
        let plan = try await service.preview(files: [record(a), record(b), record(different)], scope: scope)
        checkEqual(plan.duplicates.count, 1); checkEqual(plan.duplicates.first?.files.count, 2)
        checkTrue(plan.suggestions.isEmpty)
        checkEqual(try Data(contentsOf: a), bytes); checkEqual(try FileStamp.read(a), stamp)
        guard let group = plan.duplicates.first, let selected = group.files.first(where: { $0.url == b }) else { failCheck("Missing duplicate group"); return }
        await rejects { _ = try await service.apply(reviewID: plan.id, selected: Set(group.files.map(\.id))) }
        checkTrue(FileManager.default.fileExists(atPath: a.path)); checkTrue(FileManager.default.fileExists(atPath: b.path))
        let result = try await service.apply(reviewID: plan.id, selected: [selected.id])
        checkEqual(result.receipts.count, 1); checkTrue(result.errors.isEmpty)
        checkFalse(FileManager.default.fileExists(atPath: b.path))
        checkEqual(try Data(contentsOf: a), bytes); checkEqual(try Data(contentsOf: result.receipts[0].trashed), bytes)
        checkTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("Cleanup/\(plan.id).json").path))
        await rejects { _ = try await service.apply(reviewID: plan.id, selected: [selected.id]) }
        checkTrue(FileManager.default.fileExists(atPath: different.path))
    }
    static func safeguards() async throws {
        let (base, scope, data) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let a = try write("Original.txt", in: scope), b = try write("Copy.txt", in: scope)
        let excluded = scope.appendingPathComponent("Protected")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        let protected = try write("Protected.txt", in: excluded)
        let symbolic = scope.appendingPathComponent("Linked.txt")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: a)
        let service = CleanupService(directory: data, trash: TestCleanupTrash(destination: base.appendingPathComponent("Trash")))
        let files = try [a, b, protected, symbolic].map { try record($0) }
        var plan = try await service.preview(files: files, scope: scope, excluding: [excluded])
        checkEqual(plan.duplicates.first?.files.count, 2)
        checkTrue(plan.files.allSatisfy { $0.url != symbolic && $0.url != protected })
        let selection = plan.files.first { $0.url == b }!
        try Data("changed contents".utf8).write(to: a)
        await rejects { _ = try await service.apply(reviewID: plan.id, selected: [selection.id]) }
        checkTrue(FileManager.default.fileExists(atPath: b.path))
        try Data("same document bytes".utf8).write(to: a)
        plan = try await service.preview(files: try [a,b].map { try record($0) }, scope: scope)
        let candidate = plan.files.first { $0.url == b }!
        await rejects { _ = try await service.apply(reviewID: plan.id, selected: [candidate.id], excluding: [b]) }
        checkTrue(FileManager.default.fileExists(atPath: b.path))
        // New project markers after review prevent cleanup too.
        plan = try await service.preview(files: try [a,b].map { try record($0) }, scope: scope)
        let projectCandidate = plan.files.first { $0.url == b }!
        _ = try write("package.json", in: scope, text: "{}")
        await rejects { _ = try await service.apply(reviewID: plan.id, selected: [projectCandidate.id]) }
        checkTrue(FileManager.default.fileExists(atPath: a.path))
        // Hard links are not duplicate storage savings and must be excluded.
        try FileManager.default.removeItem(at: scope.appendingPathComponent("package.json"))
        let hard = scope.appendingPathComponent("Hard.txt")
        try FileManager.default.linkItem(at: a, to: hard)
        plan = try await service.preview(files: try [a,b,hard].map { try record($0) }, scope: scope)
        checkTrue(plan.duplicates.isEmpty)
        checkTrue(plan.files.allSatisfy { $0.url != a && $0.url != hard })
    }
    static func suggestions() async throws {
        let (base, scope, data) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let installer = try write("setup.dmg", in: scope, text: "old installer"), recent = try write("new.dmg", in: scope, text: "new installer!")
        let old = try write("Draft.txt", in: scope, text: "older distinct draft"), newer = try write("Final.txt", in: scope, text: "newer distinct document")
        let now = Date(), then = now.addingTimeInterval(-100 * 86400)
        for url in [installer, old] { try FileManager.default.setAttributes([.modificationDate: then], ofItemAtPath: url.path) }
        let service = CleanupService(directory: data, trash: FailingCleanupTrash())
        let files = try [record(installer), record(recent), record(old, vector: [1,0], engine: "test"), record(newer, vector: [1,0.01], engine: "test")]
        let plan = try await service.preview(files: files, scope: scope, now: now)
        checkTrue(plan.duplicates.isEmpty); checkEqual(plan.suggestions.count, 2); checkTrue(plan.usesEmbeddings)
        checkTrue(plan.suggestions.contains { $0.kind == .installer && $0.url == installer })
        checkTrue(plan.suggestions.contains { $0.kind == .related && $0.relatedURL == newer && $0.evidence.contains("distinct") })
        checkTrue(FileManager.default.fileExists(atPath: old.path))
        let noModel = try await service.preview(files: try [installer,recent,old,newer].map { try record($0) }, scope: scope)
        checkEqual(noModel.suggestions.count, 1); checkFalse(noModel.usesEmbeddings)
        let limited = try await service.preview(files: files, scope: scope, limit: 1)
        checkTrue(limited.limited)
    }
    static func trashFailure() async throws {
        let (base, scope, data) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let a = try write("A.txt", in: scope), b = try write("B.txt", in: scope)
        let service = CleanupService(directory: data, trash: FailingCleanupTrash())
        let plan = try await service.preview(files: [record(a),record(b)], scope: scope)
        let result = try await service.apply(reviewID: plan.id, selected: [plan.files.first!.id])
        checkTrue(result.receipts.isEmpty); checkEqual(result.errors.count, 1)
        checkEqual(try Data(contentsOf: a), try Data(contentsOf: b))
    }
}
