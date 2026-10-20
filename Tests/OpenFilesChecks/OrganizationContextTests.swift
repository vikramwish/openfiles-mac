import Foundation
import OpenFilesCore

private struct ContextWithoutEmbeddings: EmbeddingBackend {
    let identifier = "context-no-model"
    func vector(for text: String) async -> [Double]? { nil }
}

struct OrganizationContextChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Organization uses named course, client, and trip folders", folderContext),
        ("Image organization uses scene evidence, OCR, and recorded location", imageContext),
        ("Context organization works without embeddings and moves to nested folders safely", nestedMoves)
    ]
    private static func dynamicContext(_ file: FileRecord) -> OrganizationContext? {
        OrganizationContext.dynamicSuggestions(for: [file], roots: [file.root])[file.id]
    }
    private static func record(_ path: String, terms: [String] = []) -> FileRecord {
        FileRecord(id: UUID(), url: URL(fileURLWithPath: path), root: URL(fileURLWithPath: "/Fixtures"), size: 10, modified: .distantPast, isProject: false, sensitive: false, vector: nil, searchTerms: terms)
    }
    private static func image(subjects: [(String, Double)], terms: [String] = [], names: [String] = [], lat: Double? = nil, lon: Double? = nil) throws -> ImageContentIndex {
        var location: [String: Any] = ["names": names]
        if let lat, let lon { location["latitude"] = lat; location["longitude"] = lon }
        let json: [String: Any] = ["revision": "fixture", "subjects": subjects.map { ["name": $0.0, "confidence": $0.1] }, "textTerms": terms, "location": location]
        return try JSONDecoder().decode(ImageContentIndex.self, from: JSONSerialization.data(withJSONObject: json))
    }
    static func folderContext() async throws {
        let lecture = record("/Fixtures/Documents/Courses/COMP1511/lecture-02.pdf", terms: ["education", "lecture"])
        checkEqual(dynamicContext(lecture)?.folders, ["Courses", "COMP1511"])
        let proposal = record("/Fixtures/Documents/Clients/Acme/proposal.pdf", terms: ["proposal", "client"])
        checkEqual(dynamicContext(proposal)?.folders, ["Clients", "Acme"])
        let itinerary = record("/Fixtures/Documents/Trips/Japan 2025/itinerary.pdf", terms: ["travel", "itinerary"])
        checkEqual(dynamicContext(itinerary)?.folders, ["Trips", "Japan 2025"])
        checkNil(dynamicContext(record("/Fixtures/Downloads/unknown.bin")))
    }
    static func imageContext() async throws {
        var photo = record("/Fixtures/Pictures/Trips/Japan/IMG_0001.jpg")
        photo.imageContent = try image(subjects: [("beach", 0.95), ("outdoor", 0.9)])
        checkEqual(dynamicContext(photo)?.folders, ["Trips", "Japan"])
        checkTrue(dynamicContext(photo)?.reasons.joined().contains("Japan") == true)
        photo.url = URL(fileURLWithPath: "/Fixtures/Documents/Clients/Acme/logo.png")
        checkEqual(dynamicContext(photo)?.folders, ["Clients", "Acme"])
        photo.url = URL(fileURLWithPath: "/Fixtures/Documents/Courses/COMP1511/diagram.png")
        checkEqual(dynamicContext(photo)?.folders, ["Courses", "COMP1511"])
        photo.url = URL(fileURLWithPath: "/Fixtures/Pictures/IMG_0001.jpg")
        photo.imageContent = try image(subjects: [("zebra", 0.9)])
        checkEqual(dynamicContext(photo)?.folders, ["Zebra"])
        photo.imageContent = try image(subjects: [("beach", 0.2)])
        checkNil(dynamicContext(photo))
        photo.imageContent = try image(subjects: [("paper", 0.8)], terms: ["receipt"])
        checkEqual(dynamicContext(photo)?.folders, ["Paper"])
        photo.imageContent = try image(subjects: [("building", 0.8)], names: ["Kyoto"])
        checkEqual(dynamicContext(photo)?.folders, ["Kyoto", "Building"])
        photo.imageContent = try image(subjects: [("building", 0.8)], lat: -33.8688, lon: 151.2093)
        checkEqual(dynamicContext(photo)?.folders, ["Sydney", "Building"])
        photo.imageContent = try image(subjects: [("beach", 0.9)], names: ["../../Outside"])
        let folders = dynamicContext(photo)!.folders
        checkTrue(folders.allSatisfy { !$0.contains("/") && $0 != "." && $0 != ".." })
    }
    static func nestedMoves() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesContext-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("Home"), data = base.appendingPathComponent("Data")
        let files = [home.appendingPathComponent("Documents/Courses/COMP1511/lecture-01.txt"), home.appendingPathComponent("Downloads/lecture-02.txt")]
        for file in files {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "Education lecture notes for the course.".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: file.path)
        }
        let library = FileLibrary(directory: data, embeddingFactory: { ContextWithoutEmbeddings() })
        _ = try await library.load(); await library.enableDefaultDiscovery(home: home); _ = try await library.scan()
        let preview = try await library.previewSemanticOrganization(home: home)
        checkTrue(preview.modelAvailable); checkEqual(preview.suggestions.count, 2)
        guard let nested = preview.suggestions.first(where: { $0.source.resolvingSymlinksInPath().path == files[0].resolvingSymlinksInPath().path }) else {
            let current = await library.current()
            throw OpenFilesError.message("No nested course suggestion; skips: \(preview.skipped); records: \(current.files.map { ($0.name, $0.indexMetadata?.detail ?? "none") })")
        }
        checkTrue(nested.destination.path.contains("/Courses/COMP1511/"))
        checkTrue(FileManager.default.fileExists(atPath: files[0].path))
        checkFalse(FileManager.default.fileExists(atPath: preview.destination.path))
        let moved = try await library.applySemanticOrganization(planID: preview.id, selected: [nested.id])
        checkEqual(moved.moved, 1); checkTrue(moved.errors.isEmpty)
        checkFalse(FileManager.default.fileExists(atPath: files[0].path))
        checkEqual(try String(contentsOf: nested.destination), "Education lecture notes for the course.")
        var next = try await library.previewSemanticOrganization(home: home)
        guard let initial = next.suggestions.first else { throw OpenFilesError.message("Missing remaining suggestion") }
        next = try await library.reviseSemanticOrganizationFolder(planID: next.id, suggestionID: initial.id, folders: ["Blocked folder", "Child"])
        guard let candidate = next.suggestions.first else { throw OpenFilesError.message("Missing remaining suggestion: \(next.skipped)") }
        let destinationFolder = candidate.destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outside = base.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destinationFolder, withDestinationURL: outside)
        let blocked = try await library.applySemanticOrganization(planID: next.id, selected: [candidate.id])
        checkEqual(blocked.moved, 0); checkEqual(blocked.errors.count, 1)
        checkTrue(FileManager.default.fileExists(atPath: files[1].path))
        checkTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
