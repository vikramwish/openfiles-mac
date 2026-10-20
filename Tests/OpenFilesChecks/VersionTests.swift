import Foundation
import OpenFilesCore

struct VersionChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Inline selective commits preserve unstaged working text", selectiveText),
        ("Cherry-pick merges selected hunks and rejects conflicts", cherryPick),
        ("Restore in place keeps an automatic recovery snapshot", restore),
        ("Selective project commits and cherry-picks preserve other files", project),
        ("Stale review, empty message and tampered restore rejection", guards),
        ("Binary document commits and automatic restoration", binary),
        ("Selective file additions and deletions and stale history", additionsAndDeletions)
    ]
    private static func fixture(_ run: (FileLibrary, URL, URL) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesVersions-\(UUID())")
        let files = base.appendingPathComponent("Files"), data = base.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = FileLibrary(directory: data)
        _ = try await library.load()
        try await run(library, files, data)
    }
    private static func write(_ url: URL, _ text: String) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private static let original = "Title\nold A\ncontext 1\ncontext 2\ncontext 3\ncontext 4\nold B\nend\n"
    private static let updated = "Title\nnew A\ncontext 1\ncontext 2\ncontext 3\ncontext 4\nnew B\nend\n"
    private static func selectiveText() async throws {
        try await fixture { library, files, _ in
            let file = files.appendingPathComponent("Notes.md")
            try write(file, original)
            _ = try await library.commit(file, message: "Baseline")
            try write(file, updated)
            let review = try await library.reviewChanges(file)
            checkEqual(review.changes.count, 2)
            let state = try await library.commitChanges(review, selected: [review.changes[0].id], message: "Change A only")
            checkEqual(state.versions.first?.message, "Change A only")
            checkEqual(try String(contentsOf: file), updated)
            let copy = try await library.exportVersion(state.versions[0], into: files)
            checkEqual(try String(contentsOf: copy), original.replacingOccurrences(of: "old A", with: "new A"))
            let pending = try await library.reviewChanges(file)
            checkEqual(pending.changes.count, 1)
            checkTrue(pending.changes[0].added.contains("new B"))
            _ = try await library.commitChanges(pending, selected: Set(pending.changes.map(\.id)), message: "Change B")
            let clean = try await library.reviewChanges(file)
            checkTrue(clean.changes.isEmpty)
        }
    }
    private static func cherryPick() async throws {
        try await fixture { library, files, _ in
            let file = files.appendingPathComponent("Notes.md")
            try write(file, original)
            _ = try await library.commit(file, message: "Baseline")
            try write(file, updated)
            let changed = try await library.commit(file, message: "Two changes")
            let version = changed.versions[0]
            try write(file, original + "unrelated local addition\n")
            let review = try await library.reviewChanges(file, versionID: version.id)
            _ = try await library.cherryPick(review, selected: [review.changes[0].id], message: "Pick A")
            checkEqual(try String(contentsOf: file), original.replacingOccurrences(of: "old A", with: "new A") + "unrelated local addition\n")
            let retry = try await library.reviewChanges(file, versionID: version.id)
            do { _ = try await library.cherryPick(retry, selected: [retry.changes[0].id], message: "Conflicting A"); failCheck("Already changed context must conflict") } catch {}
            let bothFile = files.appendingPathComponent("Both.md")
            try write(bothFile, "a\nb\nc\nd\ne\n")
            _ = try await library.commit(bothFile, message: "Base")
            try write(bothFile, "a\nB\nc\nD\ne\n")
            let both = try await library.commit(bothFile, message: "Nearby edits")
            try write(bothFile, "a\nb\nc\nd\ne\n")
            let bothReview = try await library.reviewChanges(bothFile, versionID: both.versions[0].id)
            _ = try await library.cherryPick(bothReview, selected: Set(bothReview.changes.map(\.id)), message: "Pick both")
            checkEqual(try String(contentsOf: bothFile), "a\nB\nc\nD\ne\n")
        }
    }
    private static func restore() async throws {
        try await fixture { library, files, _ in
            let file = files.appendingPathComponent("Notes.txt")
            try write(file, "first")
            let initial = try await library.commit(file, message: "First")
            try write(file, "uncommitted work")
            let review = try await library.reviewChanges(file)
            let state = try await library.restoreVersion(initial.versions[0].id, expectedDigest: review.workingDigest)
            checkEqual(try String(contentsOf: file), "first")
            checkEqual(state.versions.count, 3)
            checkTrue(state.versions[1].message.hasPrefix("Recovery before"))
            let recovery = try await library.exportVersion(state.versions[1], into: files)
            checkEqual(try String(contentsOf: recovery), "uncommitted work")
            let current = try await library.reviewChanges(file)
            _ = try await library.restoreVersion(state.versions[1].id, expectedDigest: current.workingDigest)
            checkEqual(try String(contentsOf: file), "uncommitted work")
        }
    }
    private static func project() async throws {
        try await fixture { library, files, _ in
            let folder = files.appendingPathComponent("Project.band")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let a = folder.appendingPathComponent("a.bin"), b = folder.appendingPathComponent("b.bin")
            try Data([1]).write(to: a); try Data([2]).write(to: b)
            let initial = try await library.commit(folder, message: "Base project")
            try Data([3]).write(to: a); try Data([4]).write(to: b)
            let review = try await library.reviewChanges(folder)
            checkEqual(review.changes.count, 2)
            let partial = try await library.commitChanges(review, selected: ["a.bin"], message: "Only A")
            let copy = try await library.exportVersion(partial.versions[0], into: files)
            checkEqual(try Data(contentsOf: copy.appendingPathComponent("a.bin")), Data([3]))
            checkEqual(try Data(contentsOf: copy.appendingPathComponent("b.bin")), Data([2]))
            let current = try await library.reviewChanges(folder)
            _ = try await library.restoreVersion(initial.versions[0].id, expectedDigest: current.workingDigest)
            try Data([8]).write(to: b)
            let pick = try await library.reviewChanges(folder, versionID: partial.versions[0].id)
            _ = try await library.cherryPick(pick, selected: ["a.bin"], message: "Pick file A")
            checkEqual(try Data(contentsOf: a), Data([3])); checkEqual(try Data(contentsOf: b), Data([8]))
            checkTrue(try FileManager.default.contentsOfDirectory(atPath: files.path).allSatisfy { !$0.hasPrefix(".openfiles-") })
        }
    }
    private static func guards() async throws {
        try await fixture { library, files, data in
            let file = files.appendingPathComponent("Notes.txt")
            try write(file, "first")
            let initial = try await library.commit(file, message: "Base")
            try write(file, "second")
            let review = try await library.reviewChanges(file)
            do { _ = try await library.commitChanges(review, selected: Set(review.changes.map(\.id)), message: "  "); failCheck("Empty message must be rejected") } catch {}
            try write(file, "third")
            do { _ = try await library.commitChanges(review, selected: Set(review.changes.map(\.id)), message: "Stale"); failCheck("Stale review must be rejected") } catch {}
            do { _ = try await library.restoreVersion(initial.versions[0].id, expectedDigest: review.workingDigest); failCheck("Stale restore must be rejected") } catch {}
            let payload = data.appendingPathComponent("Versions/\(initial.versions[0].id.uuidString)/Notes.txt")
            try write(payload, "corrupt")
            let digest = try FileIntegrity.digest(file)
            do { _ = try await library.restoreVersion(initial.versions[0].id, expectedDigest: digest); failCheck("Tampered snapshot must be rejected") } catch {}
            checkEqual(try String(contentsOf: file), "third")
        }
    }
    private static func additionsAndDeletions() async throws {
        try await fixture { library, files, _ in
            let folder = files.appendingPathComponent("Project")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let removed = folder.appendingPathComponent("removed.txt"), added = folder.appendingPathComponent("new.txt")
            try write(removed, "remove me")
            _ = try await library.commit(folder, message: "Base")
            try FileManager.default.removeItem(at: removed)
            try write(added, "addition")
            let review = try await library.reviewChanges(folder)
            checkEqual(review.changes.count, 2)
            _ = try await library.commitChanges(review, selected: ["removed.txt"], message: "Delete only")
            checkTrue(FileManager.default.fileExists(atPath: added.path))
            let pending = try await library.reviewChanges(folder)
            checkEqual(pending.changes.map(\.id), ["new.txt"])
            do { _ = try await library.commitChanges(review, selected: ["new.txt"], message: "Old review"); failCheck("Another commit must invalidate the old review") } catch {}
            let state = try await library.commitChanges(pending, selected: ["new.txt"], message: "Add file")
            let copy = try await library.exportVersion(state.versions[0], into: files)
            checkEqual(try String(contentsOf: copy.appendingPathComponent("new.txt")), "addition")
            checkFalse(FileManager.default.fileExists(atPath: copy.appendingPathComponent("removed.txt").path))
        }
    }
    private static func binary() async throws {
        try await fixture { library, files, _ in
            let file = files.appendingPathComponent("Deck.pptx")
            try Data([0, 255, 1]).write(to: file)
            let first = try await library.reviewChanges(file)
            checkEqual(first.kind, .document)
            let baseline = try await library.commitChanges(first, selected: ["document"], message: "Initial deck")
            try Data([0, 128, 2]).write(to: file)
            let next = try await library.reviewChanges(file)
            _ = try await library.commitChanges(next, selected: ["document"], message: "New slides")
            let review = try await library.reviewChanges(file)
            _ = try await library.restoreVersion(baseline.versions[0].id, expectedDigest: review.workingDigest)
            checkEqual(try Data(contentsOf: file), Data([0, 255, 1]))
        }
    }
}
