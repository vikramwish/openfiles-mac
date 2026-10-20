import Foundation
import OpenFilesCore

private struct DynamicNoModel: EmbeddingBackend {
    let identifier = "dynamic-no-model"
    func vector(for text: String) async -> [Double]? { nil }
}
private struct MacScopeTestTrash: CleanupTrash {
    let folder: URL
    func moveToTrash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(UUID().uuidString + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}
struct DynamicMacChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Dynamic organization names novel projects and reuses existing names without preset categories", naming),
        ("Folder edits revise only the review and stale plans cannot move files", editing),
        ("Mac scope reduction avoids duplicate traversal and cleanup groups duplicates across locations", acrossLocations)
    ]
    private static func file(_ path: String, terms: [String] = []) -> FileRecord {
        FileRecord(id: UUID(), url: URL(fileURLWithPath: path), root: URL(fileURLWithPath: "/Fixtures"), size: 1, modified: .distantPast, isProject: false, sensitive: false, vector: nil, searchTerms: terms)
    }
    static func naming() async throws {
        let a = file("/Fixtures/Downloads/Orion spectrometer budget.pdf", terms: ["orion", "spectrometer"])
        let b = file("/Fixtures/Desktop/Orion spectrometer calibration.pdf", terms: ["orion", "spectrometer"])
        let existing = file("/Fixtures/Documents/Clients/Juniper Labs/proposal.pdf", terms: ["prototype", "juniper"])
        let loose = file("/Fixtures/Downloads/update.pdf", terms: ["prototype", "juniper"])
        let unknown = file("/Fixtures/Downloads/unknown.bin")
        let plan = OrganizationContext.dynamicSuggestions(for: [a,b,existing,loose,unknown], roots: [a.root])
        checkEqual(plan[a.id]?.folders, ["Orion Spectrometer"]); checkEqual(plan[b.id]?.folders, plan[a.id]?.folders)
        checkEqual(plan[loose.id]?.folders, ["Clients", "Juniper Labs"]); checkNil(plan[unknown.id])
        let one = file("/Fixtures/Documents/Experiments/A/notes.txt", terms: ["shared", "lecture"])
        let two = file("/Fixtures/Documents/Experiments/B/notes.txt", terms: ["shared", "lecture"])
        let ambiguous = file("/Fixtures/Downloads/scan.txt", terms: ["shared", "lecture"])
        let uncertain = OrganizationContext.dynamicSuggestions(for: [one,two,ambiguous], roots: [a.root])
        checkNil(uncertain[ambiguous.id])
    }
    static func editing() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesDynamic-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("Home"), downloads = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        var sources: [URL] = []
        for name in ["Orion spectrometer budget.txt", "Orion spectrometer calibration.txt"] {
            let url = downloads.appendingPathComponent(name); sources.append(url)
            try "Orion spectrometer commissioning details".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: url.path)
        }
        let library = FileLibrary(directory: base.appendingPathComponent("Data"), embeddingFactory: { DynamicNoModel() })
        _ = try await library.load(); await library.enableDefaultDiscovery(home: home); _ = try await library.scan()
        let plan = try await library.previewSemanticOrganization(home: home)
        checkEqual(plan.suggestions.count, 2)
        guard let first = plan.suggestions.first else { failCheck("Missing dynamic suggestion"); return }
        let revised = try await library.reviseSemanticOrganizationFolder(planID: plan.id, suggestionID: first.id, folders: ["Spectrometer", "Commissioning 2027"])
        checkTrue(revised.id != plan.id)
        checkTrue(revised.suggestions.allSatisfy { $0.destination.path.contains("/Spectrometer/Commissioning 2027/") })
        checkTrue(sources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        checkFalse(FileManager.default.fileExists(atPath: revised.destination.path))
        do { _ = try await library.applySemanticOrganization(planID: plan.id, selected: [first.id]); failCheck("Edited preview must invalidate old plan") } catch {}
        do { _ = try await library.reviseSemanticOrganizationFolder(planID: revised.id, suggestionID: first.id, folders: ["..", "Escape"]); failCheck("Traversal names must be rejected") } catch {}
        let applied = try await library.applySemanticOrganization(planID: revised.id, selected: [first.id])
        checkEqual(applied.moved, 1); checkTrue(applied.errors.isEmpty)
        checkEqual(sources.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 1)
    }
    static func acrossLocations() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesMacScope-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let left = base.appendingPathComponent("UserFiles"), right = base.appendingPathComponent("ExternalFiles")
        for folder in [left,right] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let roots = MacScanScopes.reduce([left, left.appendingPathComponent("Nested"), right, left])
        checkEqual(roots.count, 2)
        checkEqual(MacScanScopes.defaults(home: left).count, 1) // Fixture defaults never scan the real Mac.
        var records: [FileRecord] = []
        for folder in [left,right] {
            let url = folder.appendingPathComponent("same.txt")
            try "identical across locations".write(to: url, atomically: true, encoding: .utf8)
            let stamp = try FileStamp.read(url)
            records.append(FileRecord(id: UUID(), url: url, root: folder, size: stamp.size, modified: stamp.modified, isProject: false, sensitive: false, vector: nil))
            for (name, text) in [("package.json", "{}"), ("package-lock.json", "{}"), ("node_modules/sample/index.js", "library")] {
                let path = folder.appendingPathComponent("Project").appendingPathComponent(name)
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: path, atomically: true, encoding: .utf8)
            }
        }
        let trash = MacScopeTestTrash(folder: base.appendingPathComponent("TestTrash"))
        let service = CleanupService(directory: base.appendingPathComponent("Data"), trash: trash)
        let review = try await service.preview(files: records, scope: left, scopes: roots)
        checkEqual(review.duplicates.count, 1); checkEqual(review.duplicates.first?.files.count, 2)
        guard let candidate = review.files.first else { failCheck("Missing cross-location duplicate"); return }
        let result = try await service.apply(reviewID: review.id, selected: [candidate.id])
        checkEqual(result.receipts.count, 1); checkTrue(result.errors.isEmpty)
        checkEqual(records.filter { FileManager.default.fileExists(atPath: $0.url.path) }.count, 1)
        let dev = DeveloperCleanupService(directory: base.appendingPathComponent("DevData"), trash: trash)
        let artifacts = try await dev.preview(scope: left, scopes: roots)
        checkEqual(artifacts.items.count, 2); checkTrue(artifacts.items.allSatisfy(\.canTrash))
    }
}
