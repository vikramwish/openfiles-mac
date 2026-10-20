import Foundation
import OpenFilesCore

enum OptimizationBenchmarks {
    static func mixed(_ args: [String]) async throws {
        let count = args.firstIndex(of: "--count").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 400
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesMixedBench-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Corpus")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<count {
            let content: String
            let name: String
            if i % 5 == 0 {
                name = "Document-\(i).txt"
                content = "Document \(i / 10). " + String(repeating: "Planning a product launch with studio design, marketing milestones and customer feedback. ", count: 12)
            } else { name = "Binary-file-\(i).bin"; content = "opaque bytes" }
            try content.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let library = FileLibrary(directory: base.appendingPathComponent("Data"))
        _ = try await library.load(); try await library.addRoot(root)
        let coldStart = Date(); let cold = try await library.scan(); let coldSeconds = Date().timeIntervalSince(coldStart)
        let warmStart = Date(); let warm = try await library.scan(); let warmSeconds = Date().timeIntervalSince(warmStart)
        try emit(["files": count, "textFiles": count / 5, "metadataOnlyFiles": count - count / 5,
            "coldSeconds": coldSeconds, "warmSeconds": warmSeconds, "inferenceCalls": cold.progress.embedded,
            "searchTokenPasses": cold.progress.tokenized, "warmContentReads": warm.progress.extracted,
            "warmInferenceCalls": warm.progress.embedded, "warmStatHits": warm.progress.statHits,
            "modelAvailable": cold.embeddingsAvailable], args: args)
    }
    static func tokens(_ args: [String]) throws {
        let text = String(repeating: "Product launches, document plans, studio microphones and design prototypes 123. ", count: 150)
        let iterations = 1000
        var baselineCount = 0, optimizedCount = 0
        let before = Date()
        for _ in 0..<iterations {
            baselineCount += text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.count
        }
        let baseline = Date().timeIntervalSince(before), begin = Date()
        for _ in 0..<iterations { optimizedCount += FileSearchQuery.words(text).count }
        let optimized = Date().timeIntervalSince(begin)
        guard baselineCount == optimizedCount else { throw OpenFilesError.message("Tokenizer output counts differ") }
        try emit(["iterations": iterations, "inputCharacters": text.count, "referenceSeconds": baseline,
            "optimizedSeconds": optimized, "speedup": baseline / optimized, "tokensPerIteration": optimizedCount / iterations], args: args)
    }
    static func emit(_ values: [String: Any], args: [String]) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if let index = args.firstIndex(of: "--output"), index + 1 < args.count { try data.write(to: URL(fileURLWithPath: args[index + 1])) }
    }
}
