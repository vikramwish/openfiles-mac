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
        ("Filename candidates cannot escape their folder or change type", names)
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
        let state = await library.current(); checkTrue(state.files.contains { $0.url == renamed.destination })
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
}
