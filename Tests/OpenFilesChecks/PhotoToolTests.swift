import Foundation
import OpenFilesCore

struct PhotoToolChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Photo duplicates require all original, edit, and Live Photo resources to match", resources),
        ("Photo cleanup retains a checked copy and rejects unknown selections", selections),
        ("Photo duplicate groups ignore unavailable resources and repeated asset IDs", unavailable),
        ("Selected Photos archives are inspected without changing originals or databases", archive),
        ("Photo archive inspection refuses linked original directories", linkedArchive)
    ]
    private static func resource(_ kind: String, _ hash: String, _ bytes: Int64 = 10) -> PhotoResourceFingerprint { .init(kind: kind, digest: hash, bytes: bytes) }
    static func resources() async throws {
        let original = resource("photo", "image"), video = resource("pairedVideo", "video"), edit = resource("adjustmentData", "edits")
        let a = PhotoFingerprint(id: "a", resources: [original, video, edit])
        let b = PhotoFingerprint(id: "b", resources: [edit, original, video])
        let c = PhotoFingerprint(id: "c", resources: [original])
        let d = PhotoFingerprint(id: "d", resources: [original, resource("pairedVideo", "different"), edit])
        let e = PhotoFingerprint(id: "e", resources: [original, video, resource("adjustmentData", "other edits")])
        let groups = PhotoDuplicates.groups([a, b, c, d, e])
        checkEqual(groups.count, 1); checkEqual(groups.first?.items.map(\.id), ["a", "b"])
        checkEqual(groups.first?.possibleSavings, 30)
    }
    static func selections() async throws {
        let groups = PhotoDuplicates.groups([PhotoFingerprint(id: "a", resources: [resource("photo", "same")]), PhotoFingerprint(id: "b", resources: [resource("photo", "same")])])
        try PhotoDuplicates.validate(["b"], in: groups)
        for selection: Set<String> in [[], ["a", "b"], ["unknown"], ["a", "unknown"]] {
            do { try PhotoDuplicates.validate(selection, in: groups); failCheck("Unsafe duplicate selection accepted") } catch {}
        }
    }
    static func unavailable() async throws {
        let a = PhotoFingerprint(id: "a", resources: [resource("photo", "same")])
        let empty = PhotoFingerprint(id: "empty", resources: [])
        let missing = PhotoFingerprint(id: "missing", resources: [resource("photo", "", 0)])
        checkTrue(PhotoDuplicates.groups([a, a, empty, missing]).isEmpty)
        checkNil(PhotoFingerprint(id: "partial", resources: [resource("photo", "same"), resource("pairedVideo", "", 0)]).signature)
    }
    static func archive() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesPhotoTools-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let library = base.appendingPathComponent("Photos.photoslibrary"), originals = library.appendingPathComponent("originals/A")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let a = originals.appendingPathComponent("one.jpg"), b = originals.appendingPathComponent("two.jpg")
        let unique = originals.appendingPathComponent("unique.heic"), database = library.appendingPathComponent("Photos.sqlite")
        let bytes = Data("original fixture bytes".utf8), db = Data("database must remain untouched".utf8)
        try bytes.write(to: a); try bytes.write(to: b); try Data("different".utf8).write(to: unique); try db.write(to: database)
        let external = base.appendingPathComponent("outside.jpg"); try bytes.write(to: external)
        try FileManager.default.createSymbolicLink(at: originals.appendingPathComponent("link.jpg"), withDestinationURL: external)
        let stamp = try FileStamp.read(a)
        let review = try await PhotoArchive.review(library)
        checkEqual(review.photos.count, 3); checkEqual(review.groups.count, 1); checkEqual(review.skipped, 1)
        checkEqual(try Data(contentsOf: database), db); checkEqual(try Data(contentsOf: a), bytes)
        checkEqual(try FileStamp.read(a), stamp)
        checkEqual(Set(review.groups.first?.items.map { URL(fileURLWithPath: $0.id).lastPathComponent } ?? []), Set(["one.jpg", "two.jpg"]))
        let job = Task { try await PhotoArchive.review(library) }; job.cancel()
        do { _ = try await job.value; failCheck("Cancelled archive scan completed") } catch is CancellationError {} catch { failCheck(error.localizedDescription) }
    }
    static func linkedArchive() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesPhotoLinks-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let library = base.appendingPathComponent("Photos.photoslibrary"), outside = base.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("image.jpg"))
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("originals"), withDestinationURL: outside)
        do { _ = try await PhotoArchive.review(library); failCheck("Linked originals were accepted") } catch {}
    }
}
