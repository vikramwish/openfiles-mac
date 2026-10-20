import Foundation
import OpenFilesCore

private actor OrganizationEmbedding: EmbeddingBackend {
    nonisolated let identifier = "organization-test"
    func vector(for text: String) -> [Double]? {
        let words = Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted))
        let names = ["work", "education", "travel", "home", "creative", "shopping", "events", "cooking"]
        return names.map { words.contains($0) ? 1.0 : 0.0 }
    }
}
private struct OrganizationFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesOrganization-\(UUID())")
    var home: URL { base.appendingPathComponent("Home") }
    var data: URL { base.appendingPathComponent("Data") }
    func write(_ relative: String, text: String = "Travel itinerary and vacation plans.") throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: url.path)
        return url
    }
    func library() async throws -> FileLibrary {
        let library = FileLibrary(directory: data, embeddingFactory: { OrganizationEmbedding() })
        _ = try await library.load()
        await library.enableDefaultDiscovery(home: home)
        _ = try await library.scan()
        return library
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

struct OrganizationChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Content organization spans nested home folders without moving during analysis", crossFolder),
        ("Semantic organization protects stale sources and destination links", staleAndSymlink),
        ("Semantic topic matching rejects ambiguity and incompatible vectors", ambiguity)
    ]
    static func crossFolder() async throws {
        let f = OrganizationFixture(); defer { f.cleanup() }
        let a = try f.write("Documents/Nested/note.txt")
        let b = try f.write("Downloads/note.txt")
        _ = try f.write("Documents/Lessons/material.txt", text: "Education study course materials and lectures.")
        let sensitive = try f.write("Documents/passport.txt")
        let source = try f.write("Projects/Code/notes.txt")
        _ = try f.write("Projects/Code/.git/config", text: "project")
        let unsupported = try f.write("Pictures/unknown.blob")
        let library = try await f.library()
        let oldPlan = try await library.previewOrganization(); checkTrue(oldPlan.isEmpty)
        let plan = try await library.previewSemanticOrganization(home: f.home)
        checkTrue(plan.modelAvailable)
        checkEqual(plan.suggestions.count, 3)
        checkTrue(plan.suggestions.contains { $0.source.lastPathComponent == "material.txt" && $0.topic == "Study" })
        checkEqual(Set(plan.suggestions.map { $0.destination.path }).count, 3)
        checkTrue(plan.suggestions.contains { $0.destination.lastPathComponent == "note (2).txt" })
        for original in [a, b, sensitive, source, unsupported] { checkTrue(FileManager.default.fileExists(atPath: original.path)) }
        checkFalse(FileManager.default.fileExists(atPath: plan.destination.path))
        let selected = plan.suggestions.first { $0.source.lastPathComponent == "material.txt" }!
        let report = try await library.applySemanticOrganization(planID: plan.id, selected: [selected.id])
        checkEqual(report.moved, 1); checkTrue(report.errors.isEmpty)
        checkTrue(FileManager.default.fileExists(atPath: selected.destination.path))
        checkTrue(FileManager.default.fileExists(atPath: a.path)); checkTrue(FileManager.default.fileExists(atPath: b.path))
        do { _ = try await library.applySemanticOrganization(planID: plan.id, selected: [selected.id]); failCheck("Consumed plan must not replay") } catch { }
    }
    static func staleAndSymlink() async throws {
        let f = OrganizationFixture(); defer { f.cleanup() }
        let source = try f.write("Documents/note.txt")
        let library = try await f.library()
        let plan = try await library.previewSemanticOrganization(home: f.home)
        checkEqual(plan.suggestions.count, 1)
        try "Travel changed after preview".write(to: source, atomically: true, encoding: .utf8)
        let stale = try await library.applySemanticOrganization(planID: plan.id, selected: Set(plan.suggestions.map(\.id)))
        checkEqual(stale.moved, 0); checkEqual(stale.errors.count, 1)
        _ = try f.write("Documents/note.txt")
        _ = try await library.scan()
        let next = try await library.previewSemanticOrganization(home: f.home)
        let outside = f.base.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: next.destination, withDestinationURL: outside)
        let blocked = try await library.applySemanticOrganization(planID: next.id, selected: Set(next.suggestions.map(\.id)))
        checkEqual(blocked.moved, 0); checkEqual(blocked.errors.count, 1)
        checkTrue(FileManager.default.fileExists(atPath: source.path))
        checkTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    static func ambiguity() async throws {
        checkNil(SemanticOrganizer.classify([1, 1], topics: ["Travel": [1, 0], "Study": [0, 1]]))
        checkNil(SemanticOrganizer.classify([0, 0], topics: ["Travel": [1, 0], "Study": [0, 1]]))
        checkNil(SemanticOrganizer.classify([1, 0], topics: ["Travel": [1], "Study": [0]]))
        checkEqual(SemanticOrganizer.classify([1, 0], topics: ["Travel": [1, 0], "Study": [0, 1]])?.topic, "Travel")
    }
}
