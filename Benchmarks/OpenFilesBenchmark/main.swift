import Foundation
import OpenFilesCore

@main
struct Benchmark {
    static func main() async throws {
        let args = CommandLine.arguments
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
}
