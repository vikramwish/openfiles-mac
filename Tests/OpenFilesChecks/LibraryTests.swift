import Foundation
import OpenFilesCore

final class LibraryChecks {
    private var base: URL!
    private var root: URL!
    private var data: URL!
    private var library: FileLibrary!
    func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesTests-\(UUID())")
        root = base.appendingPathComponent("Files"); data = base.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = FileLibrary(directory: data)
    }
    func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    private func write(_ name: String, _ text: String) throws -> URL {
        let file = root.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: file.path)
        return file
    }
    func testSearchExcludesSensitiveEmbeddingsAndPersistence() async throws {
        _ = try await library.load(); try await library.addRoot(root)
        _ = try write("Launch plan.md", "Marketing launch milestones and release planning for the creative studio.")
        _ = try write("passport.txt", "Private travel document")
        _ = try write("ordinary.txt", "password = example")
        let report = try await library.scan()
        checkEqual(report.state.files.count, 3)
        checkTrue(report.state.files.first { $0.name == "passport.txt" }!.sensitive)
        checkNil(report.state.files.first { $0.name == "passport.txt" }!.vector)
        checkNil(report.state.files.first { $0.name == "ordinary.txt" }!.vector)
        let results = await library.search("Launch plan")
        checkEqual(results.first?.name, "Launch plan.md")
        if report.embeddingsAvailable {
            let semantic = await library.search("plans for introducing a product to customers")
            checkEqual(semantic.first?.name, "Launch plan.md")
        }
        let reopened = FileLibrary(directory: data)
        let persisted = try await reopened.load()
        checkEqual(persisted.files.count, 3)
        checkFalse(persisted.autoOrganize)
    }
    func testBinaryAndProjectSnapshotsRestoreWithoutOverwriting() async throws {
        _ = try await library.load()
        let project = root.appendingPathComponent("Song.band")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("audio.bin")
        let original = Data([0, 255, 24, 78, 0, 1])
        try original.write(to: file)
        let state = try await library.commit(project, message: "First arrangement")
        try Data([2, 3]).write(to: file)
        let restored = try await library.exportVersion(state.versions[0], into: root)
        checkEqual(try Data(contentsOf: restored.appendingPathComponent("audio.bin")), original)
        checkEqual(try Data(contentsOf: file), Data([2, 3]))
        do { _ = try await library.exportVersion(state.versions[0], into: root); failCheck("Must refuse an existing restore destination") } catch {}
    }
    func testTamperedSnapshotIsRejected() async throws {
        _ = try await library.load()
        let file = try write("design.bin", "original")
        let state = try await library.commit(file, message: "Saved")
        let version = state.versions[0]
        let payload = data.appendingPathComponent("Versions/\(version.id.uuidString)/design.bin")
        try "tampered".write(to: payload, atomically: true, encoding: .utf8)
        do { _ = try await library.exportVersion(version, into: root); failCheck("Corrupt snapshot must fail integrity check") } catch {}
    }
    func testOrganizationDoesNotOverwriteOrMoveSensitiveFiles() async throws {
        _ = try await library.load(); try await library.addRoot(root)
        let source = try write("notes.txt", "a meeting agenda")
        let privateFile = try write("bank-statement.txt", "financial details")
        _ = try await library.scan()
        let plan = try await library.previewOrganization()
        checkEqual(plan.count, 1)
        let destination = root.appendingPathComponent("Organized/Documents/notes.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "already there".write(to: destination, atomically: true, encoding: .utf8)
        let report = try await library.applyOrganization()
        checkEqual(report.moved, 0); checkEqual(report.errors.count, 1)
        checkEqual(try String(contentsOf: destination), "already there")
        checkTrue(FileManager.default.fileExists(atPath: source.path))
        checkTrue(FileManager.default.fileExists(atPath: privateFile.path))
    }
    func testOrganizationVerifiesStalePreviewAndSuccessfulMove() async throws {
        _ = try await library.load(); try await library.addRoot(root)
        let file = try write("draft.txt", "first version")
        _ = try await library.scan(); _ = try await library.previewOrganization()
        try "changed".write(to: file, atomically: true, encoding: .utf8)
        let stale = try await library.applyOrganization()
        checkEqual(stale.moved, 0); checkEqual(stale.errors.count, 1)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: file.path)
        _ = try await library.scan(); _ = try await library.previewOrganization()
        let success = try await library.applyOrganization()
        checkEqual(success.moved, 1)
        checkFalse(FileManager.default.fileExists(atPath: file.path))
        checkEqual(try String(contentsOf: root.appendingPathComponent("Organized/Documents/draft.txt")), "changed")
    }
    func testBoundariesAndSymlinks() async throws {
        _ = try await library.load(); try await library.addRoot(root)
        do { try await library.addRoot(base); failCheck("Overlapping roots must fail") } catch {}
        do { _ = try await library.authorized(base.appendingPathComponent("Files-other/file")); failCheck("Sibling prefix must not be authorized") } catch {}
        let file = try write("normal.txt", "hello")
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        _ = try await library.scan()
        let current = await library.current()
        checkEqual(current.files.count, 1)
        do { _ = try await library.commit(root, message: "Symlink project"); failCheck("Symlinks in projects must be rejected") } catch {}
    }
    func testSensitiveProjectContentCannotEnterHistory() async throws {
        _ = try await library.load()
        _ = try write("notes.txt", "-----BEGIN RSA PRIVATE KEY-----")
        do { _ = try await library.commit(root, message: "Sensitive"); failCheck("Sensitive content must be excluded") } catch {}
        let state = await library.current(); checkTrue(state.versions.isEmpty)
    }
    func testOrganizationCannotFollowDestinationSymlink() async throws {
        _ = try await library.load(); try await library.addRoot(root)
        let file = try write("drawing.txt", "a studio sketch")
        let outside = base.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Organized"), withDestinationURL: outside)
        _ = try await library.scan(); _ = try await library.previewOrganization()
        let report = try await library.applyOrganization()
        checkEqual(report.moved, 0); checkEqual(report.errors.count, 1)
        checkTrue(FileManager.default.fileExists(atPath: file.path))
        checkTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testBrowserWorksWithoutConnectedRootsAndHasNoIndexCap() async throws {
        _ = try await library.load()
        let browser = FileBrowser()
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let hidden = try write(".hidden.txt", "hidden")
        _ = try write("visible.txt", "visible")
        let package = root.appendingPathComponent("Session.band", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        for index in 0..<2010 { try Data().write(to: root.appendingPathComponent("entry-\(index).bin")) }
        let items = try await browser.contents(of: root)
        checkEqual(items.count, 2013)
        checkTrue(items.first?.isFolder == true)
        checkFalse(items.contains { $0.url.lastPathComponent == hidden.lastPathComponent })
        let withHidden = try await browser.contents(of: root, showHidden: true)
        checkEqual(withHidden.count, 2014)
        checkTrue(items.first { $0.name == "Session.band" }?.isPackage == true)
        checkFalse(items.first { $0.name == "Session.band" }?.isFolder == true)
        let state = await library.current(); checkTrue(state.roots.isEmpty)
    }
    func testBrowserFolderCreationAndSymlinkNavigation() async throws {
        let browser = FileBrowser()
        let created = try await browser.createFolder(in: root, name: "New project")
        _ = try await browser.createFolder(in: created, name: "Assets")
        do { _ = try await browser.createFolder(in: root, name: "New project"); failCheck("Must refuse a collision") } catch {}
        do { _ = try await browser.createFolder(in: root, name: "../escape"); failCheck("Must refuse traversal") } catch {}
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: created)
        let entry = try await browser.item(at: alias); checkTrue(entry.isFolder)
        let contents = try await browser.contents(of: alias); checkEqual(contents.first?.name, "Assets")
    }
    func testDefaultSearchDiscoveryDoesNotAuthorizeOrganization() async throws {
        _ = try await library.load()
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let file = documents.appendingPathComponent("Brief.txt")
        try "Design project launch brief".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: file.path)
        await library.enableDefaultDiscovery(home: root)
        let report = try await library.scan()
        checkTrue(report.state.roots.isEmpty)
        checkEqual(report.state.files.count, 1)
        let search = await library.search("Brief"); checkEqual(search.first?.name, "Brief.txt")
        let plan = try await library.previewOrganization(); checkTrue(plan.isEmpty)
        do { _ = try await library.authorized(file); failCheck("Discovery must not authorize moves") } catch {}
    }
    func testFileHistoryAndSavedChangeStatus() async throws {
        _ = try await library.load()
        let first = try write("Deck.pptx", "binary presentation v1")
        let otherFolder = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let other = otherFolder.appendingPathComponent("Deck.pptx")
        try Data([1, 2, 3]).write(to: other)
        let empty = try await library.versionStatus(first)
        checkEqual(empty, "No committed versions")
        _ = try await library.commit(first, message: "First draft")
        _ = try await library.commit(other, message: "Unrelated deck")
        let clean = try await library.versionStatus(first)
        checkEqual(clean, "All saved changes committed")
        try "presentation v2".write(to: first, atomically: true, encoding: .utf8)
        let changed = try await library.versionStatus(first)
        checkEqual(changed, "Saved changes to commit")
        _ = try await library.commit(first, message: "Updated slides")
        let versions = await library.versions(for: first)
        checkEqual(versions.count, 2)
        checkEqual(versions.first?.message, "Updated slides")
        let restored = try await library.exportVersion(versions[1], into: root)
        checkEqual(restored.pathExtension, "pptx")
        checkEqual(try String(contentsOf: restored), "binary presentation v1")
        checkEqual(try String(contentsOf: first), "presentation v2")
        let reopened = FileLibrary(directory: data)
        _ = try await reopened.load()
        let history = await reopened.versions(for: first)
        checkEqual(history, versions)
        try FileManager.default.removeItem(at: first)
        do { _ = try await library.versionStatus(first); failCheck("Missing working file must report an error") } catch {}
    }
    func testPureRules() {
        checkEqual(FileRules.category(URL(fileURLWithPath: "/a/image.HEIC")), "Images")
        checkEqual(FileRules.cosine([1, 0], [1, 0]), 1, accuracy: 0.001)
        checkEqual(FileRules.cosine([0, 0], [1, 0]), 0)
        checkFalse(FileRules.contains(URL(fileURLWithPath: "/foo"), URL(fileURLWithPath: "/foobar")))
    }
}
