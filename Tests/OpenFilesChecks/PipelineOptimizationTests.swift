import Foundation
import OpenFilesCore

struct PipelineOptimizationChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Fast tokenizer preserves ASCII and Unicode search semantics", tokenization),
        ("Sparse file graph updates incrementally and excludes sensitive records", relationships),
        ("Search readers remain consistent while graph postings change", concurrentReaders)
    ]
    static func tokenization() async throws {
        let samples = ["", "PDFs in Downloads THIS_WEEK 123", "Über CAFÉ—東京_42", "Straße Ελληνικά 🚀 UTF8", "İSTANBUL résumé e\u{301} FÖÖ", "abc...def--ghi /path/name.txt", String(repeating: "word123 ", count: 6000)]
        for sample in samples {
            let reference = sample.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            checkEqual(FileSearchQuery.words(sample), reference)
        }
    }
    private static func file(_ name: String, words: [String], vector: [Double], sensitive: Bool = false) -> FileRecord {
        FileRecord(id: UUID(), url: URL(fileURLWithPath: "/Synthetic/Folder/" + name), root: URL(fileURLWithPath: "/Synthetic"), size: 100, modified: Date(timeIntervalSince1970: 100), isProject: false, sensitive: sensitive, vector: vector, searchTerms: words)
    }
    static func relationships() async throws {
        let catalog = SearchCatalog()
        let origin = file("Garden plan.txt", words: ["plants", "watering", "garden"], vector: [1, 0])
        let peer = file("Garden notes.txt", words: ["plants", "watering", "garden"], vector: [1, 0])
        let other = file("Invoice.txt", words: ["invoice", "payments"], vector: [0, 1])
        let privateFile = file("Private.txt", words: ["plants", "watering", "garden"], vector: [1, 0], sensitive: true)
        let files = [origin, peer, other, privateFile]
        catalog.replace(files)
        let related = catalog.relatedFiles(to: origin.url)
        checkEqual(related.first?.file.id, peer.id)
        checkEqual(related.first?.similarity ?? 0, 1, accuracy: 0.0001)
        checkTrue(related.first?.sharedTerms.contains("garden") == true)
        checkFalse(related.contains { $0.file.sensitive })
        checkTrue(catalog.relatedFiles(to: privateFile.url).isEmpty)
        let revision = catalog.revision
        catalog.upsert(files); checkEqual(catalog.revision, revision)
        catalog.replace(files); checkEqual(catalog.revision, revision)
        catalog.upsert([], removing: [peer.url.path])
        checkTrue(catalog.relatedFiles(to: origin.url).allSatisfy { $0.file.id != peer.id })
        checkTrue(catalog.matches("notes").isEmpty)
    }
    static func concurrentReaders() async throws {
        let catalog = SearchCatalog()
        let origin = file("Garden plan.txt", words: ["garden", "plants"], vector: [1, 0])
        let peer = file("Garden notes.txt", words: ["garden", "plants"], vector: [1, 0])
        catalog.replace([origin, peer])
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<100 {
                    var changed = peer; changed.modified = Date(timeIntervalSince1970: Double(100 + index))
                    catalog.upsert([changed])
                }
            }
            for _ in 0..<3 {
                group.addTask {
                    for _ in 0..<100 {
                        checkEqual(catalog.matches("garden").count, 2)
                        checkEqual(catalog.relatedFiles(to: origin.url).first?.file.id, peer.id)
                    }
                }
            }
        }
        checkEqual(catalog.count, 2)
    }
}
