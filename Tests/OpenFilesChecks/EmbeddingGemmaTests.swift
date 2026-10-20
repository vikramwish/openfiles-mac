import Foundation
import OpenFilesCore
#if canImport(OpenFilesMLX)
import OpenFilesMLX
#endif

private actor RetrievalBackend: EmbeddingBackend {
    nonisolated let identifier: String
    nonisolated let displayName = "Test retrieval model"
    var documents: [String] = []
    var queries: [String] = []
    private let blockQuery: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    init(_ identifier: String, blockQuery: Bool = false) { self.identifier = identifier; self.blockQuery = blockQuery }
    func vector(for text: String) -> [Double]? { documents.append(text); return [1, 0] }
    func queryVector(for text: String) async -> [Double]? {
        queries.append(text)
        if blockQuery { await withCheckedContinuation { continuation = $0 } }
        return [1, 0]
    }
    func resumeQuery() { continuation?.resume(); continuation = nil }
}

struct EmbeddingGemmaChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Retrieval task routing, cache isolation, and model switching", routingAndSwitching),
        ("Stale queries cannot populate a new model's cache", staleQuery),
        ("Unknown legacy vectors cannot enter a new embedding space", legacyVectors),
        ("EmbeddingGemma prompts and checkpoint identity", checkpointIdentity)
    ]

    private static func fixture() throws -> (base: URL, root: URL, data: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesGemmaChecks-\(UUID())")
        let root = base.appendingPathComponent("Files"), data = base.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "garden astronomy".write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try "private material".write(to: root.appendingPathComponent("password.txt"), atomically: true, encoding: .utf8)
        return (base, root, data)
    }

    static func routingAndSwitching() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let first = RetrievalBackend("retrieval-a"), second = RetrievalBackend("retrieval-b")
        let library = FileLibrary(directory: f.data, embeddingFactory: { first })
        _ = try await library.load(); try await library.addRoot(f.root)
        let cold = try await library.scan()
        checkEqual(cold.progress.engine, first.displayName)
        let documents = await first.documents
        checkEqual(documents, ["garden astronomy"]) // sensitive files never reach the model
        let query = "find my garden astronomy files"
        let matches = await library.searchMatches(query)
        checkEqual(matches.count, 1); checkEqual(matches[0].score, 2.4, accuracy: 0.000001)
        _ = await library.search(query)
        let queries = await first.queries
        checkEqual(queries, [query]) // retrieval receives the original sentence, once
        try await library.setEmbeddingBackend { second }
        let beforeScan = await library.searchMatches(query)
        checkEqual(beforeScan.count, 1); checkEqual(beforeScan[0].score, 2, accuracy: 0.000001)
        let newQueries = await second.queries; checkEqual(newQueries, [query])
        let rebuilt = try await library.scan()
        checkEqual(rebuilt.progress.embedded, 1); checkEqual(rebuilt.progress.statHits, 0)
        let afterScan = await library.searchMatches(query)
        checkEqual(afterScan[0].score, 2.4, accuracy: 0.000001)

        var settings = IndexSettings(); settings.paused = true
        try await library.configureIndexing(settings)
        let pass = Task { try await library.scan() }
        try await IndexChecks.wait { library.indexMonitor.snapshot().phase == .paused }
        do { try await library.setEmbeddingBackend { first }; failCheck("Changed model during an active pass") }
        catch { checkTrue(error.localizedDescription.contains("Stop indexing")) }
        await library.cancelIndexing(); _ = try await pass.value
    }

    static func staleQuery() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let old = RetrievalBackend("old", blockQuery: true), new = RetrievalBackend("new")
        let library = FileLibrary(directory: f.data, embeddingFactory: { old })
        _ = try await library.load(); try await library.addRoot(f.root); _ = try await library.scan()
        let pending = Task { await library.search("garden astronomy") }
        try await IndexChecks.wait { await old.waiting }
        try await library.setEmbeddingBackend { new }
        await old.resumeQuery()
        let stale = await pending.value; checkTrue(stale.isEmpty)
        _ = await library.search("garden astronomy")
        let queries = await new.queries; checkEqual(queries, ["garden astronomy"])
    }

    static func legacyVectors() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let backend = RetrievalBackend("new-model")
        let first = FileLibrary(directory: f.data, embeddingFactory: { backend })
        _ = try await first.load(); try await first.addRoot(f.root); _ = try await first.scan()
        let manifest = f.data.appendingPathComponent("library.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        var files = json["files"] as! [[String: Any]]
        for index in files.indices { files[index].removeValue(forKey: "indexMetadata"); files[index]["vector"] = [1.0, 0.0] }
        json["files"] = files
        try JSONSerialization.data(withJSONObject: json).write(to: manifest, options: .atomic)
        let restarted = FileLibrary(directory: f.data, embeddingFactory: { backend })
        _ = try await restarted.load()
        let matches = await restarted.searchMatches("garden astronomy")
        checkEqual(matches.count, 1); checkEqual(matches[0].score, 2, accuracy: 0.000001)
    }

    static func checkpointIdentity() async throws {
        checkEqual(EmbeddingGemmaInput.query("  find my notes\n"), "task: search result | query: find my notes")
        checkEqual(EmbeddingGemmaInput.document("Hello"), "title: none | text: Hello")
        checkEqual(EmbeddingGemmaInput.document(String(repeating: "界", count: 5000)), "title: none | text: " + String(repeating: "界", count: 4000))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GemmaCheckpoint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ value: String) throws { try Data(value.utf8).write(to: folder.appendingPathComponent(name)) }
        try write("config.json", "{\"model_type\":\"embedding_gemma2\"}")
        try write("tokenizer.json", "{}"); try write("tokenizer_config.json", "{}")
        // These are identity fixtures, not loadable inference weights.
        try write("model.safetensors", "weights-a")
        let first = try EmbeddingGemmaCheckpoint.inspect(directory: folder)
        checkEqual(first.identifier, try EmbeddingGemmaCheckpoint.inspect(directory: folder).identifier)
        try write("model.safetensors", "weights-b") // same length, different embedding space
        let second = try EmbeddingGemmaCheckpoint.inspect(directory: folder)
        checkFalse(first.identifier == second.identifier)
        try write("tokenizer_config.json", "{\"add_bos_token\":true}")
        checkFalse(second.identifier == (try EmbeddingGemmaCheckpoint.inspect(directory: folder)).identifier)
        try write("config.json", "{\"model_type\":\"gemma3\"}")
        do { _ = try EmbeddingGemmaCheckpoint.inspect(directory: folder); failCheck("Accepted another model architecture") }
        catch { checkTrue(error.localizedDescription.contains("EmbeddingGemma 2")) }
    }

    static func realModelIfRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["OPENFILES_TEST_EMBEDDINGGEMMA_MODEL"], !path.isEmpty else {
            print("SKIP real EmbeddingGemma 2 inference (set OPENFILES_TEST_EMBEDDINGGEMMA_MODEL to a downloaded checkpoint)")
            return
        }
        #if canImport(OpenFilesMLX)
        let backend = try await EmbeddingGemmaBackend.load(directory: URL(fileURLWithPath: path))
        guard let query = await backend.queryVector(for: "How do bees make honey?"),
              let relevant = await backend.vector(for: "Bees collect nectar from flowers and turn it into honey in their hive."),
              let unrelated = await backend.vector(for: "A spreadsheet lists the quarterly budget and office rental expenses.") else {
            throw OpenFilesError.message("Real EmbeddingGemma inference returned no vector.")
        }
        guard query.count == 768, relevant.count == 768, unrelated.count == 768,
              abs(VectorMath.dot(query, query) - 1) < 0.001,
              VectorMath.dot(query, relevant) > VectorMath.dot(query, unrelated) else {
            throw OpenFilesError.message("Real EmbeddingGemma retrieval failed its dimension, normalization, or relevance check.")
        }
        print("PASS real EmbeddingGemma 2 retrieval, dimensions, and normalization")
        #else
        throw OpenFilesError.message("The real model check requires OPENFILES_MLX=1 on an Apple Silicon Mac with Swift 6.3+.")
        #endif
    }
}
