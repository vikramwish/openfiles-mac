import Foundation
import OpenFilesCore

@main
struct Benchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        if args.contains("--mixed") { try await OptimizationBenchmarks.mixed(args); return }
        if args.contains("--tokens") { try OptimizationBenchmarks.tokens(args); return }
        if args.contains("--graph") { try GraphBenchmarks.run(args); return }
        if args.contains("--search-only") { try searchBenchmark(args); return }
        let count = args.firstIndex(of: "--count").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 48
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesBenchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Corpus")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let topics = ["Designing a product launch with marketing milestones and customer feedback.", "Planning a rail journey through Japanese gardens and ancient temples.", "Recording acoustic instruments in a studio with microphones and an audio interface.", "Documenting a mechanical engineering prototype with CAD drawings and material testing."]
        for index in 0..<count {
            let text = "Document \(index / 2). " + String(repeating: topics[(index / 2) % topics.count] + " ", count: 12)
            try text.write(to: root.appendingPathComponent(String(format: "Document-%03d.txt", index)), atomically: true, encoding: .utf8)
        }
        let library = FileLibrary(directory: base.appendingPathComponent("Data"))
        _ = try await library.load(); try await library.addRoot(root)
        let start = Date(); let cold = try await library.scan(); let coldSeconds = Date().timeIntervalSince(start)
        let warmStart = Date(); let warm = try await library.scan(); let warmSeconds = Date().timeIntervalSince(warmStart)
        let restartStart = Date()
        let reopened = FileLibrary(directory: base.appendingPathComponent("Data")); _ = try await reopened.load()
        let restart = try await reopened.scan(); let restartSeconds = Date().timeIntervalSince(restartStart)
        let result: [String: Any] = ["documents": count, "uniqueContents": (count + 1) / 2, "coldSeconds": coldSeconds, "warmSeconds": warmSeconds, "modelAvailable": cold.embeddingsAvailable, "coldInferenceCalls": cold.progress.embedded, "coldContentReuses": cold.progress.objectHits, "warmInferenceCalls": warm.progress.embedded, "warmContentReads": warm.progress.extracted, "warmTokenizationPasses": warm.progress.tokenized, "warmStatHits": warm.progress.statHits, "restartSecondsIncludingLoad": restartSeconds, "restartStatHits": restart.progress.statHits]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
        if let index = args.firstIndex(of: "--output"), index + 1 < args.count { try json.write(to: URL(fileURLWithPath: args[index + 1])) }
    }
    static func searchBenchmark(_ args: [String]) throws {
        let count = args.firstIndex(of: "--count").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 10000
        let root = URL(fileURLWithPath: "/Synthetic/Downloads"), now = Date()
        let catalog = SearchCatalog()
        let records = (0..<count).map { index -> FileRecord in
            let name = "Document-\(index)." + (index % 3 == 0 ? "pdf" : "txt")
            let modified = now.addingTimeInterval(-Double(index % 60) * 86400)
            let terms = FileSearchQuery.words(index % 4 == 0 ? "Australian government taxation invoice" : "Studio design launch plan project")
            return FileRecord(id: UUID(), url: root.appendingPathComponent(name), root: root, size: 1024,
                              modified: modified, isProject: false, sensitive: false, vector: nil, searchTerms: terms)
        }
        let start = Date(); catalog.replace(records); let build = Date().timeIntervalSince(start)
        let queries = ["government files", "launch plan", "PDFs in Downloads this month", "recent files", "all files", "govern"]
        var samples: [Double] = [], byQuery: [String: [Double]] = [:]
        for index in 0..<120 {
            let query = queries[index % queries.count], begin = ContinuousClock.now
            let hits = catalog.matches(query, now: now)
            let duration = begin.duration(to: .now).components
            let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
            samples.append(milliseconds); byQuery[query, default: []].append(milliseconds)
            if hits.isEmpty { throw OpenFilesError.message("Benchmark query returned no results: " + query) }
        }
        samples.sort()
        let result: [String: Any] = ["documents": count, "queries": samples.count, "indexBuildSeconds": build, "p50Milliseconds": samples[samples.count / 2], "p95Milliseconds": samples[Int(Double(samples.count) * 0.95)], "maxMilliseconds": samples.last!, "meanByQueryMilliseconds": byQuery.mapValues { $0.reduce(0, +) / Double($0.count) }, "documentReadsPerQuery": 0, "inferenceCallsPerFastQuery": 0, "corpus": "Synthetic metadata and normalized terms; no real file access; includes prefix, type/date/location, and all-files navigation"]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
        if let index = args.firstIndex(of: "--output"), index + 1 < args.count { try json.write(to: URL(fileURLWithPath: args[index + 1])) }
    }

}
