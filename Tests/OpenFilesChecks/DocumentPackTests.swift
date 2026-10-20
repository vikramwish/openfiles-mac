import Foundation
import Darwin
import OpenFilesCore

struct DocumentPackChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Document packs persist private metadata and preserve originals", persistence),
        ("Document packs export reviewed copies with missing-item checklist", checklist),
        ("Document packs reject unreviewed, changed and missing sources", reviewGuards),
        ("Document packs preserve duplicate filenames and refuse unsafe sources", sourceSafety)
    ]
    private static func fixture(_ run: (DocumentPackStore, URL, URL, URL) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesPacks-\(UUID())")
        let files = base.appendingPathComponent("Files"), data = base.appendingPathComponent("Metadata"), output = base.appendingPathComponent("Export")
        for folder in [files, output] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        try await run(DocumentPackStore(directory: data), files, data, output)
    }
    private static func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private static func exportedFiles(_ directory: URL) -> [URL] {
        let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
        return walker.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    private static func persistence() async throws {
        try await fixture { store, files, data, _ in
            let initial = try await store.load(); checkTrue(initial.isEmpty)
            let passport = files.appendingPathComponent("passport.txt")
            try write(passport, "Explicitly selected sensitive document contents")
            var pack = DocumentPackTemplate.rental.makePack()
            let another = DocumentPackTemplate.rental.makePack()
            checkTrue(pack.id != another.id); checkTrue(pack.items[0].id != another.items[0].id)
            pack = try await store.attach(passport, to: pack.items[0].id, in: pack)
            pack = try await store.attach(passport, to: pack.items[0].id, in: pack)
            checkEqual(pack.attachmentCount, 1)
            checkFalse(pack.items[0].attachments[0].reviewed)
            let fresh = DocumentPackStore(directory: data)
            let loaded = try await fresh.load()
            checkEqual(loaded, [pack])
            let metadata = data.appendingPathComponent("\(pack.id.uuidString).json")
            checkFalse(try String(contentsOf: metadata).contains("Explicitly selected sensitive document contents"))
            let attributes = try FileManager.default.attributesOfItem(atPath: metadata.path)
            checkEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            pack = try await fresh.review(pack.items[0].attachments[0].id, in: pack)
            checkEqual(pack.reviewedCount, 1)
            checkEqual(pack.items[0].attachments[0].reviewedDigest, try FileIntegrity.digest(passport))
            let reviewed = try await DocumentPackStore(directory: data).load()
            checkEqual(reviewed, [pack])
            pack = try await fresh.removeAttachment(pack.items[0].attachments[0].id, in: pack)
            checkEqual(pack.attachmentCount, 0)
            try await fresh.delete(pack.id)
            let deleted = try await fresh.load(); checkTrue(deleted.isEmpty)
            checkEqual(try String(contentsOf: passport), "Explicitly selected sensitive document contents")
        }
    }
    private static func checklist() async throws {
        try await fixture { store, files, _, output in
            let identity = files.appendingPathComponent("identity.txt")
            try write(identity, "Document reviewed for recipient")
            var pack = DocumentPackTemplate.rental.makePack()
            pack = try await store.attach(identity, to: pack.items[0].id, in: pack)
            pack = try await store.reviewAll(pack)
            let exported = try await store.export(pack, to: output)
            let all = exportedFiles(exported)
            checkEqual(all.count, 2)
            let readme = try String(contentsOf: exported.appendingPathComponent("README.txt"))
            checkTrue(readme.contains("Proof of income: MISSING"))
            checkTrue(readme.contains("Rental history: Not supplied"))
            checkTrue(readme.contains("not official requirements"))
            checkFalse(readme.contains(identity.path))
            let copy = all.first { $0.lastPathComponent != "README.txt" }!
            checkEqual(try Data(contentsOf: copy), try Data(contentsOf: identity))
            checkEqual((try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let repeated = try await store.export(pack, to: output)
            checkTrue(repeated != exported)
            checkTrue(FileManager.default.fileExists(atPath: copy.path))
            checkEqual(try String(contentsOf: identity), "Document reviewed for recipient")
        }
    }
    private static func reviewGuards() async throws {
        try await fixture { store, files, _, output in
            let source = files.appendingPathComponent("receipt.txt")
            try write(source, "Original receipt")
            var pack = DocumentPackTemplate.custom.makePack()
            pack = try await store.attach(source, to: pack.items[0].id, in: pack)
            do { _ = try await store.export(pack, to: output); failCheck("An unreviewed attachment must not export") } catch {}
            checkTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
            pack = try await store.reviewAll(pack)
            try write(source, "Changed receipt")
            do { _ = try await store.export(pack, to: output); failCheck("Changed content requires a new review") } catch {}
            checkTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
            pack = try await store.reviewAll(pack)
            let second = files.appendingPathComponent("later.txt")
            try write(second, "Second receipt")
            pack = try await store.attach(second, to: pack.items[0].id, in: pack)
            pack = try await store.reviewAll(pack)
            try FileManager.default.removeItem(at: second)
            do { _ = try await store.export(pack, to: output); failCheck("A missing attachment must fail and clean up earlier copies") } catch {}
            checkTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
            checkEqual(try String(contentsOf: source), "Changed receipt")
            pack = try await store.removeAttachment(pack.items[0].attachments[1].id, in: pack)
            let final = try await store.export(pack, to: output)
            checkEqual(exportedFiles(final).count, 2)
        }
    }
    private static func sourceSafety() async throws {
        try await fixture { store, files, _, output in
            let first = files.appendingPathComponent("A/receipt.txt"), second = files.appendingPathComponent("B/receipt.txt")
            try write(first, "First document"); try write(second, "Second document")
            var pack = DocumentPackTemplate.custom.makePack()
            pack.title = "../../Outside\nPack"; pack.items[0].title = "../../Documents"
            pack = try await store.attach(first, to: pack.items[0].id, in: pack)
            pack = try await store.attach(second, to: pack.items[0].id, in: pack)
            pack = try await store.reviewAll(pack)
            let exported = try await store.export(pack, to: output)
            checkEqual(exported.deletingLastPathComponent().resolvingSymlinksInPath(), output.resolvingSymlinksInPath())
            let copies = exportedFiles(exported).filter { $0.lastPathComponent != "README.txt" }
            checkEqual(copies.count, 2)
            checkEqual(Set(try copies.map { try String(contentsOf: $0) }), ["First document", "Second document"])
            let link = files.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
            do { _ = try await store.attach(link, to: pack.items[0].id, in: pack); failCheck("Symbolic-link attachments must be refused") } catch {}
            let linkedFolder = files.appendingPathComponent("LinkedFolder")
            try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: first.deletingLastPathComponent())
            do { _ = try await store.attach(linkedFolder.appendingPathComponent("receipt.txt"), to: pack.items[0].id, in: pack); failCheck("Symbolic-link ancestors must be refused") } catch {}
            do { _ = try await store.attach(files, to: pack.items[0].id, in: pack); failCheck("Directories must be refused") } catch {}
            let placeholder = files.appendingPathComponent(".receipt.pdf.icloud")
            try write(placeholder, "placeholder")
            do { _ = try await store.attach(placeholder, to: pack.items[0].id, in: pack); failCheck("Cloud placeholders must be refused") } catch {}
            let fifo = files.appendingPathComponent("pipe")
            guard mkfifo(fifo.path, mode_t(0o600)) == 0 else { throw OpenFilesError.message("Could not create pipe fixture") }
            do { _ = try await store.attach(fifo, to: pack.items[0].id, in: pack); failCheck("Special files must be refused without blocking") } catch {}
            let destinationLink = files.appendingPathComponent("LinkedExport")
            try FileManager.default.createSymbolicLink(at: destinationLink, withDestinationURL: output)
            do { _ = try await store.export(pack, to: destinationLink); failCheck("Symbolic-link export destinations must be refused") } catch {}
            // A valid reviewed source replaced with a link must not be followed during export.
            try FileManager.default.removeItem(at: first)
            try FileManager.default.createSymbolicLink(at: first, withDestinationURL: second)
            do { _ = try await store.export(pack, to: output); failCheck("Export must recheck source file safety") } catch {}
            checkEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).count, 1)
        }
    }
}
