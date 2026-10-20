import Foundation
import OpenFilesCore

private actor RenameEmbedding: EmbeddingBackend {
    nonisolated let identifier = "rename-test"
    var documents: [String] = []
    var queries: [String] = []
    var available = true
    func vector(for text: String) -> [Double]? { documents.append(text); return available ? [1, 0] : nil }
    func queryVector(for text: String) -> [Double]? {
        queries.append(text)
        return text.contains("Travel") ? [1, 0] : [0, 1]
    }
    func disable() { available = false }
}

private struct RenameFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesRename-\(UUID())").resolvingSymlinksInPath()
    var source: URL { base.appendingPathComponent("Files/scan.txt") }
    let contents = "Appendix unrelated notes\nTravel itinerary for Kyoto\nTravel bookings and train journeys"
    func make(_ backend: RenameEmbedding) async throws -> FileLibrary {
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: source, atomically: true, encoding: .utf8)
        let library = FileLibrary(directory: base.appendingPathComponent("Data"), embeddingFactory: { backend })
        _ = try await library.load(); try await library.addRoot(source.deletingLastPathComponent())
        return library
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

struct RenameChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Embedding-ranked names require review and preserve bytes and extension", rankingAndRename),
        ("Rename rejects collisions, changed sources, and linked parents", staleAndCollision),
        ("Rename protects sensitive files, unavailable models, and stale model previews", eligibility),
        ("Filename candidates cannot escape their folder or change type", names),
        ("Batch names retain all previews and apply only checked rows", batchSelection),
        ("Batch rename preflights collisions and stale sources before moving anything", batchPreflight),
        ("Batch suggestions explain exclusions, naming patterns, and cancellation", batchEligibility)
    ]
    static func rankingAndRename() async throws {
        let fixture = RenameFixture(); defer { fixture.cleanup() }
        let backend = RenameEmbedding(), library = try await fixture.make(backend)
        let preview = try await library.previewRename(fixture.source)
        checkEqual(preview.suggestions.count, 2)
        checkTrue(preview.suggestions.allSatisfy { $0.name.hasPrefix("Travel") && $0.name.hasSuffix(".txt") })
        let docs = await backend.documents, queries = await backend.queries
        checkEqual(docs, [fixture.contents]); checkTrue(queries.contains("Appendix unrelated notes"))
        checkEqual(try String(contentsOf: fixture.source, encoding: .utf8), fixture.contents)
        checkEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.source.deletingLastPathComponent().path), ["scan.txt"])
        let renamed = try await library.applyRename(previewID: preview.id, name: "Kyoto travel plan.txt")
        checkNil(renamed.indexWarning)
        checkEqual(try String(contentsOf: renamed.destination, encoding: .utf8), fixture.contents)
        checkFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        let state = await library.current(); checkTrue(state.files.contains { $0.url.resolvingSymlinksInPath().standardizedFileURL == renamed.destination.resolvingSymlinksInPath().standardizedFileURL })
        do { _ = try await library.applyRename(previewID: preview.id, name: "Another name.txt"); failCheck("Replayed a consumed rename") } catch { }
    }
    static func staleAndCollision() async throws {
        let fixture = RenameFixture(); defer { fixture.cleanup() }
        let library = try await fixture.make(RenameEmbedding())
        let collision = fixture.source.deletingLastPathComponent().appendingPathComponent("Existing.txt")
        try "keep this".write(to: collision, atomically: true, encoding: .utf8)
        let first = try await library.previewRename(fixture.source)
        do { _ = try await library.applyRename(previewID: first.id, name: "existing.txt"); failCheck("Overwrote a destination") } catch { }
        checkEqual(try String(contentsOf: collision, encoding: .utf8), "keep this")
        let next = try await library.previewRename(fixture.source)
        try "Travel changed content".write(to: fixture.source, atomically: true, encoding: .utf8)
        do { _ = try await library.applyRename(previewID: next.id, name: "New name.txt"); failCheck("Renamed a changed source") } catch { }
        checkTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        let linked = try await library.previewRename(fixture.source)
        let parent = fixture.source.deletingLastPathComponent(), moved = fixture.base.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
        do { _ = try await library.applyRename(previewID: linked.id, name: "New name.txt"); failCheck("Followed a substituted parent") } catch { }
        checkTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("scan.txt").path))
    }
    static func eligibility() async throws {
        let fixture = RenameFixture(); defer { fixture.cleanup() }
        let backend = RenameEmbedding(), library = try await fixture.make(backend)
        let preview = try await library.previewRename(fixture.source)
        try await library.setEmbeddingBackend { RenameEmbedding() }
        do { _ = try await library.applyRename(previewID: preview.id, name: "New name.txt"); failCheck("Used a stale model preview") } catch { }
        try await library.setEmbeddingBackend { backend }; await backend.disable()
        do { _ = try await library.previewRename(fixture.source); failCheck("Invented names without a model") } catch { }
        let fresh = RenameEmbedding(); try await library.setEmbeddingBackend { fresh }
        try "Password credential material".write(to: fixture.source, atomically: true, encoding: .utf8)
        do { _ = try await library.previewRename(fixture.source); failCheck("Embedded sensitive content") } catch { }
        let docs = await fresh.documents; checkTrue(docs.isEmpty)
        checkTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }
    static func names() async throws {
        let source = URL(fileURLWithPath: "/tmp/scan.txt")
        for name in ["../outside.txt", "folder/name.txt", "folder\\name.txt", "new.pdf", ".hidden.txt", "name\0.txt", "SCAN.txt"] {
            do { try RenameNames.validate(name, source: source); failCheck("Accepted invalid name: \(name)") } catch { }
        }
        let candidates = RenameNames.candidates(from: "# Kyoto / Travel: Plans\nKyoto Travel Plans\nPassword credentials", extension: "txt")
        checkEqual(candidates, ["Kyoto Travel Plans.txt"])
        try RenameNames.validate(candidates[0], source: source)
    }

    static func batchSelection() async throws {
        let fixture = RenameFixture(); defer { fixture.cleanup() }
        let library = try await fixture.make(RenameEmbedding())
        var urls = [fixture.source]
        for index in 1..<20 {
            let url = fixture.source.deletingLastPathComponent().appendingPathComponent("scan-\(index).txt")
            try fixture.contents.write(to: url, atomically: true, encoding: .utf8); urls.append(url)
        }
        let batch = try await library.previewBatchRename(urls)
        checkEqual(batch.rows.count, 20); checkTrue(batch.rows.allSatisfy { $0.preview != nil && $0.problem == nil })
        // Unrelated single-file reviews must not evict batch rows.
        for _ in 0..<17 { _ = try await library.previewRename(fixture.source) }
        let result = try await library.applyBatchRename(batch.id, names: [urls[0]: "Kyoto notes.txt", urls[1]: "Travel plans.txt"])
        checkEqual(result.renamed, 2); checkEqual(result.outcomes.count, 2)
        for entry in result.outcomes {
            checkNil(entry.message)
            if let destination = entry.destination { checkEqual(try String(contentsOf: destination, encoding: .utf8), fixture.contents) }
        }
        for untouched in urls.dropFirst(2) { checkTrue(FileManager.default.fileExists(atPath: untouched.path)) }
        do { _ = try await library.applyBatchRename(batch.id, names: [urls[2]: "Another.txt"]); failCheck("Replayed batch") } catch { }
    }

    static func batchPreflight() async throws {
        let fixture = RenameFixture(); defer { fixture.cleanup() }
        let library = try await fixture.make(RenameEmbedding())
        let second = fixture.source.deletingLastPathComponent().appendingPathComponent("second.txt")
        try fixture.contents.write(to: second, atomically: true, encoding: .utf8)
        let batch = try await library.previewBatchRename([fixture.source, second])
        do { _ = try await library.applyBatchRename(batch.id, names: [fixture.source: "Plan.txt", second: "plan.txt"]); failCheck("Accepted duplicate batch destinations") } catch { }
        checkTrue(FileManager.default.fileExists(atPath: fixture.source.path)); checkTrue(FileManager.default.fileExists(atPath: second.path))
        try "Travel changed after review".write(to: second, atomically: true, encoding: .utf8)
        do { _ = try await library.applyBatchRename(batch.id, names: [fixture.source: "One.txt", second: "Two.txt"]); failCheck("Moved files before finishing stale batch checks") } catch { }
        checkTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        checkFalse(FileManager.default.fileExists(atPath: fixture.source.deletingLastPathComponent().appendingPathComponent("One.txt").path))
        // A rejected preflight remains editable: choose only the still-valid row.
        let result = try await library.applyBatchRename(batch.id, names: [fixture.source: "One.txt"])
        checkEqual(result.renamed, 1)
    }

    static func batchEligibility() async throws {
        let fixture = RenameFixture(); defer { fixture.cleanup() }
        let library = try await fixture.make(RenameEmbedding())
        let sensitive = fixture.source.deletingLastPathComponent().appendingPathComponent("password.txt")
        try fixture.contents.write(to: sensitive, atomically: true, encoding: .utf8)
        let batch = try await library.previewBatchRename([fixture.source, sensitive, fixture.source])
        checkEqual(batch.rows.count, 2)
        checkTrue(batch.rows.contains { $0.source == sensitive && $0.preview == nil && $0.problem != nil })
        checkEqual(BatchRenamePattern.name("Travel plan.txt", prefix: " Project ", modified: nil), "Project - Travel plan.txt")
        let dated = BatchRenamePattern.name("Travel plan.txt", prefix: "Project", modified: Date())
        checkTrue(dated.hasSuffix(" - Project - Travel plan.txt")); checkEqual(String(dated.prefix(10)).count, 10)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await library.applyBatchRename(batch.id, names: [fixture.source: "New name.txt"])
        }
        do { _ = try await cancelled.value; failCheck("Cancelled batch changed files") } catch { }
        checkTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        try await library.setEmbeddingBackend { RenameEmbedding() }
        do { _ = try await library.applyBatchRename(batch.id, names: [fixture.source: "New name.txt"]); failCheck("Used a batch from another model") } catch { }
        do { _ = try await library.previewBatchRename([]); failCheck("Accepted empty batch") } catch { }
    }
}
