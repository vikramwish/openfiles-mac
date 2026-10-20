import Foundation
import OpenFilesCore

enum GraphBenchmarks {
    static func run(_ args: [String]) throws {
        let count = args.firstIndex(of: "--count").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 10000
        var records: [FileRecord] = []; records.reserveCapacity(count)
        for i in 0..<count {
            let topic = i % 20
            var vector = Array(repeating: 0.0, count: 512); vector[topic] = 1
            records.append(FileRecord(id: UUID(), url: URL(fileURLWithPath: "/Synthetic/Projects/Note-\(i).txt"), root: URL(fileURLWithPath: "/Synthetic"), size: 1024, modified: Date(timeIntervalSince1970: Double(i)), isProject: false, sensitive: false, vector: vector,
                searchTerms: ["topic\(topic)", "feature\(topic)", "project\(topic)"]))
        }
        let catalog = SearchCatalog(), start = Date(); catalog.replace(records)
        let build = Date().timeIntervalSince(start)
        var samples: [Double] = [], correct = 0, total = 0
        for i in 0..<100 {
            let source = records[(i * 97) % count], before = ContinuousClock.now
            let matches = catalog.relatedFiles(to: source.url)
            let elapsed = before.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            for match in matches { total += 1; if match.sharedTerms.contains(source.searchTerms![0]) { correct += 1 } }
        }
        samples.sort()
        let revision = catalog.revision, unchangedStart = Date(); catalog.upsert(records)
        let unchanged = Date().timeIntervalSince(unchangedStart)
        guard revision == catalog.revision else { throw OpenFilesError.message("Unchanged graph batch changed revision") }
        try OptimizationBenchmarks.emit(["files": count, "vectorDimensions": 512, "buildSeconds": build,
            "queries": samples.count, "p50Milliseconds": samples[50], "p95Milliseconds": samples[95],
            "topicPrecision": total > 0 ? Double(correct) / Double(total) : 0,
            "unchangedUpsertSeconds": unchanged, "maxCandidateBudget": 1024,
            "note": "Synthetic clustered vectors; bounded candidate graph, not exact global nearest neighbors; no document reads or inference"], args: args)
    }
}
