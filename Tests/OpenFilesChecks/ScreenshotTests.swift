import Foundation
import OpenFilesCore

private final class ScreenshotTestMetadata: ScreenshotMetadataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ScreenshotFileMetadata] = [:]
    func set(_ name: String, _ value: ScreenshotFileMetadata) { lock.lock(); defer { lock.unlock() }; values[name] = value }
    func metadata(for url: URL) -> ScreenshotFileMetadata { lock.lock(); defer { lock.unlock() }; return values[url.lastPathComponent] ?? .init() }
}
private struct ScreenshotTestTrash: CleanupTrash {
    let destination: URL
    func moveToTrash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}

struct ScreenshotChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Screenshot suggestions protect recent opens, edits, saved items, and important records", policy),
        ("Screenshot review distinguishes unknown viewing history from evidence of disuse", unknownUsage),
        ("Screenshot detection uses metadata or a capture-style name, not image dimensions", detection),
        ("File screenshot cleanup ranks evidence and rechecks new opens before Trash", cleanup)
    ]
    static func policy() async throws {
        let now = Date(), old = now.addingTimeInterval(-150 * 86400)
        var signals = ScreenshotSignals(source: .photosMetadata, created: old, modified: old, contentTerms: ["error", "retry", "timeout"])
        checkTrue(ScreenshotReview.assess(signals, now: now) != nil)
        signals.kept = true; checkNil(ScreenshotReview.assess(signals, now: now)); signals.kept = false
        signals.modified = now; checkNil(ScreenshotReview.assess(signals, now: now)); signals.modified = old
        signals.created = now; checkNil(ScreenshotReview.assess(signals, now: now)); signals.created = old
        signals.lastUsed = now.addingTimeInterval(-5 * 86400); checkNil(ScreenshotReview.assess(signals, now: now)); signals.lastUsed = nil
        for word in ["receipt", "invoice", "ticket", "insurance", "medical", "contract", "password", "passport"] {
            signals.contentTerms = [word]; checkNil(ScreenshotReview.assess(signals, now: now))
        }
    }
    static func unknownUsage() async throws {
        let now = Date(), old = now.addingTimeInterval(-200 * 86400)
        let signals = ScreenshotSignals(source: .systemMetadata, created: old, modified: old)
        let assessment = ScreenshotReview.assess(signals, now: now)
        checkTrue(assessment?.evidence.contains("does not prove") == true)
        checkTrue(assessment?.evidence.contains("not understood") == true)
        let younger = ScreenshotSignals(source: .systemMetadata, created: now.addingTimeInterval(-120 * 86400), modified: old)
        checkNil(ScreenshotReview.assess(younger, now: now))
        checkTrue(ScreenshotReview.textOverlap(["error", "server", "retry", "request", "failed", "timeout", "connection"], ["error", "server", "retry", "request", "failed", "timeout", "connection"]))
        checkFalse(ScreenshotReview.textOverlap(["screen", "error"], ["screen", "error"]))
    }
    static func detection() async throws {
        checkEqual(ScreenshotReview.source(for: URL(fileURLWithPath: "/tmp/IMG_0123.png"), metadata: .init(isScreenshot: true)), .systemMetadata)
        checkEqual(ScreenshotReview.source(for: URL(fileURLWithPath: "/tmp/Screen Shot 2024-01-01.png"), metadata: .init()), .filename)
        checkNil(ScreenshotReview.source(for: URL(fileURLWithPath: "/tmp/holiday.png"), metadata: .init()))
        checkNil(ScreenshotReview.source(for: URL(fileURLWithPath: "/tmp/Screenshot 2024.png"), metadata: .init(isScreenshot: false)))
        checkNil(ScreenshotReview.source(for: URL(fileURLWithPath: "/tmp/Screenshot.txt"), metadata: .init(isScreenshot: true)))
    }
    static func cleanup() async throws {
        let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent("OpenFilesScreenshots-\(UUID())").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("Desktop"), data = base.appendingPathComponent("Data"), trash = base.appendingPathComponent("Trash")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date(), old = now.addingTimeInterval(-150 * 86400), metadata = ScreenshotTestMetadata()
        var files: [FileRecord] = []
        for (index, name) in ["Screen Shot temporary.png", "Screen Shot receipt.png", "Screen Shot recent-open.png", "Screen Shot tagged.png"].enumerated() {
            let url = root.appendingPathComponent(name)
            try Data(String(repeating: "x", count: index + 12).utf8).write(to: url)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            let stamp = try FileStamp.read(url)
            var file = FileRecord(id: UUID(), url: url, root: root, size: stamp.size, modified: stamp.modified, isProject: false, sensitive: false, vector: nil)
            let terms = name.contains("receipt") ? ["receipt", "total"] : ["error", "retry", "loading"]
            let json = try JSONSerialization.data(withJSONObject: ["revision": "fixture", "subjects": [], "textTerms": terms])
            file.imageContent = try JSONDecoder().decode(ImageContentIndex.self, from: json)
            files.append(file)
            metadata.set(name, .init(isScreenshot: true, created: old, lastUsed: name.contains("recent-open") ? now : old, tags: name.contains("tagged") ? ["Keep"] : []))
        }
        let service = CleanupService(directory: data, trash: ScreenshotTestTrash(destination: trash), screenshotMetadata: metadata)
        var plan = try await service.preview(files: files, scope: root, now: now)
        checkEqual(plan.suggestions.count, 1); checkEqual(plan.suggestions.first?.kind, .screenshot)
        guard let candidate = plan.suggestions.first else { failCheck("Missing old screenshot suggestion"); return }
        checkTrue(candidate.evidence.contains("temporary")); checkTrue(candidate.reviewScore > 0)
        metadata.set(candidate.url.lastPathComponent, .init(isScreenshot: true, created: old, lastUsed: now))
        do { _ = try await service.apply(reviewID: plan.id, selected: [candidate.id]); failCheck("Recently opened screenshot moved") } catch {}
        checkTrue(fm.fileExists(atPath: candidate.url.path))
        metadata.set(candidate.url.lastPathComponent, .init(isScreenshot: true, created: old, lastUsed: old))
        plan = try await service.preview(files: files, scope: root, now: now)
        guard let reviewed = plan.suggestions.first else { failCheck("Missing refreshed screenshot suggestion"); return }
        let result = try await service.apply(reviewID: plan.id, selected: [reviewed.id])
        checkEqual(result.receipts.count, 1); checkTrue(result.errors.isEmpty)
        checkFalse(fm.fileExists(atPath: reviewed.url.path))
        checkTrue(fm.fileExists(atPath: root.appendingPathComponent("Screen Shot receipt.png").path))
    }
}
