import Foundation
import OpenFilesCore

private struct UnavailableSearchEmbedding: EmbeddingBackend {
    let identifier = "search-test-no-model"
    func vector(for text: String) async -> [Double]? { nil }
}

extension LibraryChecks {
    func testGroundedNaturalLanguageSearch() async throws {
        let query = FileSearchQuery("find all my australian government related files")
        checkEqual(query.terms, ["australian", "government"])
        checkTrue(query.coverage(in: "ATO notice") == 1)
        checkTrue(query.coverage(in: "services.gov.au") == 1)
        checkNil(query.score(name: "Studio budget.csv", content: "A studio production budget", similarity: 0.99))
        checkNil(query.score(name: "INSTALLER", content: "pip", similarity: 0.99))
        checkNil(query.score(name: "Australian holiday.md", content: "A travel itinerary", similarity: 0.99))
        checkTrue(query.score(name: "letter.md", content: "Australian government correspondence") != nil)
        checkTrue(FileSearchQuery("find invoice.pdf").score(name: "invoice.pdf", content: "") != nil)
        checkFalse(FileSearchQuery.allows(URL(fileURLWithPath: "/Users/test/Downloads/venv/lib/site-packages/pkg/INSTALLER")))
        checkFalse(FileSearchQuery.allows(URL(fileURLWithPath: "/Users/test/project/node_modules/package/notes.md")))
        checkFalse(FileSearchQuery.allows(URL(fileURLWithPath: "/Users/test/Library/Application Support/Arc/listdata.json")))
        checkFalse(FileSearchQuery.allows(URL(fileURLWithPath: "/Applications/Example.app/Contents/Resources/sample.pdf")))
        checkTrue(FileSearchQuery.allows(URL(fileURLWithPath: "/Users/test/Documents/government.pdf")))
        checkEqual(query.coverage(in: "collaborator"), 0)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesSearch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixtures = [
            "ATO notice.md": "Australian government correspondence from the tax office.",
            "letter.md": "A letter from the Australian government about an application.",
            "Studio budget.csv": "Design studio expenses, audio production and wages.",
            "Australian holiday.md": "Travel itinerary for Sydney and Melbourne.",
            "INSTALLER": "Australian government pip package"
        ]
        for (name, text) in fixtures { try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let library = FileLibrary(directory: base.appendingPathComponent("Data"), embeddingFactory: { UnavailableSearchEmbedding() })
        _ = try await library.load(); try await library.addRoot(root); _ = try await library.scan()
        let matches = await library.searchMatches("find all my australian government related files")
        checkEqual(Set(matches.map { $0.file.name }), Set(["ATO notice.md", "letter.md"]))
        checkEqual(matches.first?.file.name, "ATO notice.md")
        checkEqual(matches.first?.reason, "Filename matches")
        let empty = await library.search("find all my files")
        checkTrue(empty.isEmpty)
    }
}
