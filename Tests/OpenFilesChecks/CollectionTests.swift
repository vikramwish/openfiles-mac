import Foundation
import OpenFilesCore

struct CollectionChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Collections persist references across reloads without changing originals", persistence),
        ("Collections retain unavailable files and reconnect references", reconnect),
        ("Collection mutations preserve membership and reject invalid input", validation),
        ("Corrupt collection metadata is never replaced by an edit", corruptMetadata)
    ]
    private static func fixture(_ run: (CollectionStore, URL, URL) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesCollections-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let storage = base.appendingPathComponent("Metadata")
        try await run(CollectionStore(directory: storage), base, storage)
    }
    private static func persistence() async throws {
        try await fixture { store, base, storage in
            let first = base.appendingPathComponent("Trip/booking.txt")
            let second = base.appendingPathComponent("Expenses/booking.txt")
            for url in [first, second] {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "Original document: \(url.path)".write(to: url, atomically: true, encoding: .utf8)
            }
            let before = try [first, second].map { try Data(contentsOf: $0) }
            let collection = try await store.create(title: "  Japan trip  ", files: [first, second, first])
            checkEqual(collection.title, "Japan trip")
            checkEqual(collection.files, [first, second])
            let another = try await store.create(title: "Expense claim", files: [first])
            let fresh = CollectionStore(directory: storage)
            let loaded = try await fresh.load()
            checkEqual(loaded.count, 2)
            checkEqual(loaded.first { $0.id == collection.id }, collection)
            try await fresh.remove(first, from: collection.id)
            let remaining = try await fresh.load()
            checkEqual(remaining.first { $0.id == another.id }?.files, [first])
            checkEqual(remaining.first { $0.id == collection.id }?.files, [second])
            try await fresh.delete(collection.id)
            try await fresh.delete(another.id)
            checkEqual(try [first, second].map { try Data(contentsOf: $0) }, before)
            let empty = try await fresh.load(); checkTrue(empty.isEmpty)
            let metadata = storage.appendingPathComponent("collections.json")
            let attributes = try FileManager.default.attributesOfItem(atPath: metadata.path)
            checkEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
    private static func reconnect() async throws {
        try await fixture { store, base, storage in
            let source = base.appendingPathComponent("draft.txt"), moved = base.appendingPathComponent("renamed.txt")
            try "Work in progress".write(to: source, atomically: true, encoding: .utf8)
            let collection = try await store.create(title: "Project", files: [source])
            try FileManager.default.moveItem(at: source, to: moved)
            let reloaded = try await CollectionStore(directory: storage).load()
            checkEqual(reloaded.first?.files, [source])
            try await store.rename(collection.id, title: "Renamed project")
            try await store.replace(source, with: moved, in: collection.id)
            let updated = try await store.load()
            checkEqual(updated.first?.files, [moved])
            checkEqual(try String(contentsOf: moved), "Work in progress")
            try FileManager.default.removeItem(at: moved)
            try await store.remove(moved, from: collection.id)
            let removed = try await store.load(); checkEqual(removed.first?.files, [])
        }
    }
    private static func validation() async throws {
        try await fixture { store, base, _ in
            let file = base.appendingPathComponent("notes.txt")
            try "Private contents never copied into metadata".write(to: file, atomically: true, encoding: .utf8)
            let collection = try await store.create(title: "Project")
            async let first: Void = store.add([file], to: collection.id)
            async let second: Void = store.rename(collection.id, title: "Updated project")
            _ = try await (first, second)
            try await store.add([file, file], to: collection.id)
            let valid = try await store.load()
            checkEqual(valid.first?.title, "Updated project"); checkEqual(valid.first?.files, [file])
            do { _ = try await store.create(title: " \n "); failCheck("Accepted empty title") } catch {}
            do { try await store.add([URL(string: "https://example.com/file")!], to: collection.id); failCheck("Accepted remote reference") } catch {}
            do { try await store.add([base.appendingPathComponent("absent")], to: collection.id); failCheck("Accepted unavailable addition") } catch {}
            do { try await store.add([file], to: UUID()); failCheck("Accepted deleted collection") } catch {}
            let after = try await store.load(); checkEqual(after, valid)
        }
    }
    private static func corruptMetadata() async throws {
        try await fixture { store, _, storage in
            _ = try await store.create(title: "Project")
            let file = storage.appendingPathComponent("collections.json")
            let bad = Data("not valid json".utf8)
            try bad.write(to: file)
            do { _ = try await store.create(title: "Must not replace corruption"); failCheck("Ignored corrupt metadata") } catch {}
            checkEqual(try Data(contentsOf: file), bad)
        }
    }
}
