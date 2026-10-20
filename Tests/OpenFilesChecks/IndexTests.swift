import Foundation
import OpenFilesCore

private actor InferenceCounter {
    var count = 0
    func increment() { count += 1 }
}
private actor TestEmbeddingBackend: EmbeddingBackend {
    nonisolated let identifier: String
    let counter: InferenceCounter
    let delay: Duration
    init(_ counter: InferenceCounter, identifier: String = "test-v1-prep2", delay: Duration = .milliseconds(5)) { self.counter = counter; self.identifier = identifier; self.delay = delay }
    func vector(for text: String) async -> [Double]? {
        await counter.increment(); try? await Task.sleep(for: delay)
        return [1, 2, 3, Double(text.utf8.count % 7 + 1)]
    }
}
private struct IndexFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesIndexChecks-\(UUID())")
    var root: URL { base.appendingPathComponent("Files", isDirectory: true) }
    var data: URL { base.appendingPathComponent("Data", isDirectory: true) }
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func write(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name); try text.write(to: url, atomically: true, encoding: .utf8); return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

struct IndexChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Stat/content caches, deduplication, persisted objects, query memoization", incremental),
        ("Model identity invalidation and missing-object recovery", invalidation),
        ("Pause/cancel checkpoints and restart", pauseAndResume),
        ("File-change race rejects stale inference", changingSource),
        ("Index limits and user exclusions are reported", exclusions),
        ("Legacy inline index and summary migrations", legacyMigration),
        ("Vector math is normalized and numerically consistent", vectorMath)
    ]
    static func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw OpenFilesError.message("Timed out waiting for index state")
    }
    static func incremental() async throws {
        let f = try IndexFixture(); defer { f.cleanup() }; let counter = InferenceCounter()
        for index in 0..<30 { _ = try f.write("Doc-\(index).txt", "Launch topic \(index / 2). The bird is in the garden.") }
        _ = try f.write("passport.txt", "Private identifier")
        let library = FileLibrary(directory: f.data, embeddingFactory: { TestEmbeddingBackend(counter) })
        _ = try await library.load(); try await library.addRoot(f.root)
        let cold = try await library.scan()
        checkEqual(cold.progress.embedded, 15); checkEqual(cold.progress.tokenized, 15); checkEqual(cold.progress.objectHits, 15)
        checkEqual(cold.progress.extracted, 30); checkEqual(cold.progress.skipReasons["Sensitive content"], 1)
        let calls = await counter.count; checkEqual(calls, 15)
        let warm = try await library.scan()
        checkEqual(warm.progress.statHits, 31); checkEqual(warm.progress.extracted, 0); checkEqual(warm.progress.bytesRead, 0)
        checkEqual(warm.progress.tokenized, 0); checkEqual(warm.progress.embedded, 0)
        let manifest = try String(contentsOf: f.data.appendingPathComponent("library.json"))
        checkFalse(manifest.contains("The bird is in the garden")); checkFalse(manifest.contains("\"vector\""))
        let restarted = FileLibrary(directory: f.data, embeddingFactory: { TestEmbeddingBackend(counter) })
        let restored = try await restarted.load(); checkEqual(restored.files.filter { $0.vector != nil }.count, 30)
        let warmRestart = try await restarted.scan(); checkEqual(warmRestart.progress.statHits, 31)
        let beforeSearch = await counter.count
        _ = await restarted.search("launch"); _ = await restarted.search("launch")
        let afterSearch = await counter.count; checkEqual(afterSearch, beforeSearch + 1)
        let changed = f.root.appendingPathComponent("Doc-0.txt"), originalDate = try changed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try "Launch topic 0. The wolf is in the garden.".write(to: changed, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: changed.path)
        let edited = try await restarted.scan(); checkEqual(edited.progress.extracted, 1); checkEqual(edited.progress.embedded, 1)
        let renamed = f.root.appendingPathComponent("Renamed.txt")
        try FileManager.default.moveItem(at: f.root.appendingPathComponent("Doc-1.txt"), to: renamed)
        let rename = try await restarted.scan(); checkEqual(rename.progress.objectHits, 1); checkEqual(rename.progress.embedded, 0)
    }
    static func invalidation() async throws {
        let f = try IndexFixture(); defer { f.cleanup() }; let counter = InferenceCounter()
        _ = try f.write("notes.txt", "A product design brief")
        let first = FileLibrary(directory: f.data, embeddingFactory: { TestEmbeddingBackend(counter) })
        _ = try await first.load(); try await first.addRoot(f.root); _ = try await first.scan()
        let second = FileLibrary(directory: f.data, embeddingFactory: { TestEmbeddingBackend(counter, identifier: "test-v2-prep2") })
        _ = try await second.load(); let changed = try await second.scan()
        checkEqual(changed.progress.embedded, 1); checkEqual(changed.progress.statHits, 0)
        let key = changed.state.files[0].indexMetadata!.objectKey!
        try FileManager.default.removeItem(at: f.data.appendingPathComponent("IndexObjects/\(key).json"))
        let third = FileLibrary(directory: f.data, embeddingFactory: { TestEmbeddingBackend(counter, identifier: "test-v2-prep2") })
        _ = try await third.load(); let repaired = try await third.scan()
        checkEqual(repaired.progress.embedded, 1); checkEqual(repaired.state.files.filter { $0.vector != nil }.count, 1)
    }
    static func pauseAndResume() async throws {
        let f = try IndexFixture(); defer { f.cleanup() }; let counter = InferenceCounter()
        for index in 0..<30 { _ = try f.write("Doc-\(index).txt", "A unique studio arrangement number \(index)") }
        let library = FileLibrary(directory: f.data, embeddingFactory: { TestEmbeddingBackend(counter, delay: .milliseconds(15)) })
        _ = try await library.load(); try await library.addRoot(f.root)
        var settings = IndexSettings(); settings.workers = 1; settings.paused = true; try await library.configureIndexing(settings)
        let task = Task { try await library.scan() }
        try await wait { library.indexMonitor.snapshot().phase == .paused }
        let paused = library.indexMonitor.snapshot(); checkEqual(paused.processed, 0)
        // Library remains responsive while paused; cancellation is not queued behind a whole scan.
        let current = await library.current(); checkTrue(current.files.isEmpty)
        try await library.pauseIndexing(false)
        try await wait { library.indexMonitor.snapshot().processed >= 3 }
        try await library.pauseIndexing(true)
        try await Task.sleep(for: .milliseconds(80)); let settled = library.indexMonitor.snapshot().processed
        try await Task.sleep(for: .milliseconds(80)); checkEqual(library.indexMonitor.snapshot().processed, settled)
        await library.cancelIndexing(); await library.waitForIndexingToStop(); let stopped = try await task.value
        checkEqual(stopped.progress.phase, .cancelled); checkTrue(stopped.state.files.count >= 3)
        let restart = FileLibrary(directory: f.data, embeddingFactory: { TestEmbeddingBackend(counter) })
        let saved = try await restart.load(); checkEqual(saved.files.count, stopped.state.files.count)
        try await restart.pauseIndexing(false); let completed = try await restart.scan()
        checkEqual(completed.progress.phase, .completed); checkEqual(completed.state.files.count, 30)
        checkTrue(completed.progress.statHits >= 3)
    }
    static func changingSource() async throws {
        let f = try IndexFixture(); defer { f.cleanup() }; let counter = InferenceCounter()
        let file = try f.write("draft.txt", "A first draft")
        let library = FileLibrary(directory: f.data, embeddingFactory: { TestEmbeddingBackend(counter, delay: .milliseconds(100)) })
        _ = try await library.load(); try await library.addRoot(f.root)
        let task = Task { try await library.scan() }
        try await wait { await counter.count > 0 }
        try "A changed draft with new content".write(to: file, atomically: true, encoding: .utf8)
        let report = try await task.value
        checkTrue(report.state.files.isEmpty); checkEqual(report.progress.skipReasons["Changed or unreadable file"], 1)
    }
    static func exclusions() async throws {
        let f = try IndexFixture(); defer { f.cleanup() }; let counter = InferenceCounter()
        for index in 0..<4 { _ = try f.write("Doc-\(index).txt", "A sample document \(index)") }
        let library = FileLibrary(directory: f.data, embeddingFactory: { TestEmbeddingBackend(counter) })
        _ = try await library.load(); try await library.addRoot(f.root)
        var settings = IndexSettings(); settings.maxFiles = 2; try await library.configureIndexing(settings)
        let limited = try await library.scan(); checkTrue(limited.progress.limitReached); checkEqual(limited.state.files.count, 2)
        settings.maxFiles = 0; settings.excludedFolders = [f.root]; try await library.configureIndexing(settings)
        let excluded = try await library.scan(); checkTrue(excluded.state.files.isEmpty); checkEqual(excluded.progress.skipReasons["User exclusion"], 1)
        let browser = FileBrowser(); let visible = try await browser.contents(of: f.root); checkEqual(visible.count, 4)
        let environment = f.root.appendingPathComponent("ProjectPython", isDirectory: true)
        try FileManager.default.createDirectory(at: environment, withIntermediateDirectories: true)
        try "home = /usr/bin".write(to: environment.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8)
        try "print('dependency')".write(to: environment.appendingPathComponent("package.py"), atomically: true, encoding: .utf8)
        settings.excludedFolders = []; try await library.configureIndexing(settings)
        let filtered = try await library.scan(); checkEqual(filtered.state.files.count, 4)
        checkEqual(filtered.progress.skipReasons["Python virtual environment"], 1)
        let environmentContents = try await browser.contents(of: environment); checkEqual(environmentContents.count, 2)
    }
    static func legacyMigration() async throws {
        let f = try IndexFixture(); defer { f.cleanup() }; let counter = InferenceCounter()
        _ = try f.write("notes.txt", "A local design document")
        let library = FileLibrary(directory: f.data, embeddingFactory: { TestEmbeddingBackend(counter) })
        _ = try await library.load(); try await library.addRoot(f.root); _ = try await library.scan()
        let manifest = f.data.appendingPathComponent("library.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        var files = json["files"] as! [[String: Any]]
        files[0].removeValue(forKey: "indexMetadata"); files[0]["vector"] = [1.0, 2.0, 3.0, 4.0]
        json["files"] = files; json.removeValue(forKey: "indexSettings")
        var summary = json["lastIndexReport"] as! [String: Any]; summary.removeValue(forKey: "activePaths"); json["lastIndexReport"] = summary
        try JSONSerialization.data(withJSONObject: json).write(to: manifest, options: .atomic)
        try FileManager.default.removeItem(at: f.data.appendingPathComponent("IndexObjects"))
        let restart = FileLibrary(directory: f.data, embeddingFactory: { TestEmbeddingBackend(counter) })
        let restored = try await restart.load(); checkEqual(restored.files.first?.vector?.count, 4)
        let migrated = try await restart.scan(); checkEqual(migrated.progress.embedded, 1)
        checkTrue(migrated.state.files[0].indexMetadata != nil)
    }
    static func vectorMath() async throws {
        let a = [1.0, 2, 3, 4], b = [4.0, 3, 2, 1]
        checkEqual(VectorMath.dot(a, b), 20, accuracy: 0.000001)
        let normalized = VectorMath.normalized(a); checkEqual(VectorMath.dot(normalized, normalized), 1, accuracy: 0.000001)
        checkEqual(VectorMath.cosine(a, b), VectorMath.dot(normalized, VectorMath.normalized(b)), accuracy: 0.000001)
        checkEqual(VectorMath.cosine([], []), 0)
    }
}
