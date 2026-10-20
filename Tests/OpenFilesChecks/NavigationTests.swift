import Foundation
import OpenFilesCore

private actor ObservedFileEvents {
    var names = Set<String>()
    func add(_ urls: [URL]) { names.formUnion(urls.map(\.lastPathComponent)) }
}

private struct NoNavigationEmbedding: EmbeddingBackend {
    let identifier = "navigation-no-model"
    func vector(for text: String) async -> [Double]? { nil }
}

enum NavigationChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Photos libraries remain whole across browse, index, sync, search, and cleanup", photosLibraries),
        ("Natural-language metadata plans and prefix postings", queryPlans),
        ("Filesystem watcher delivers real file changes", fileEvents),
        ("Search, sync and smart groups preserve original bytes, names and modification dates", readOnlySafety),
        ("Persistent search without document reads, live groups, incremental create/edit/rename/delete", persistentSync)
    ]
    static func photosLibraries() async throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("OpenFilesPhotos-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Pictures")
        let photos = root.appendingPathComponent("Family.PHOTOSLIBRARY")
        let originals = photos.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let first = originals.appendingPathComponent("image-a.jpg"), second = originals.appendingPathComponent("image-b.jpg")
        let bytes = Data("fixture image bytes".utf8)
        try bytes.write(to: first); try bytes.write(to: second)
        let browser = FileBrowser()
        let items = try await browser.contents(of: root)
        checkEqual(items.count, 1); checkEqual(items.first?.kind, "Photos Library")
        checkEqual(items.first?.isPackage, true); checkEqual(items.first?.isFolder, false)
        checkTrue(FileSearchQuery.allows(photos)); checkFalse(FileSearchQuery.allows(first))
        let library = FileLibrary(directory: base.appendingPathComponent("Data"), embeddingFactory: { NoNavigationEmbedding() })
        _ = try await library.load(); try await library.addRoot(root)
        let report = try await library.scan()
        checkEqual(report.state.files.count, 1); checkTrue(report.state.files.first?.isProject == true)
        let found = await library.search("Family")
        checkEqual(found.first?.url.path, photos.path); checkEqual(found.count, 1)
        let synced = try await library.synchronizeChanges([first, photos])
        checkEqual(synced.files.count, 1); checkEqual(synced.files.first?.url.path, photos.path)
        let plan = try await library.previewOrganization(); checkTrue(plan.isEmpty)
        let direct = FileLibrary(directory: base.appendingPathComponent("DirectData"), embeddingFactory: { NoNavigationEmbedding() })
        _ = try await direct.load(); try await direct.addRoot(photos)
        let directReport = try await direct.scan()
        checkEqual(directReport.state.files.count, 1)
        checkEqual(directReport.state.files.first?.url.resolvingSymlinksInPath().path, photos.resolvingSymlinksInPath().path)
        let nested = FileLibrary(directory: base.appendingPathComponent("NestedData"), embeddingFactory: { NoNavigationEmbedding() })
        _ = try await nested.load()
        do { try await nested.addRoot(originals); failCheck("Photos library internals must not become an organization root") } catch {}
        let records = try [first, second].map { url -> FileRecord in
            let stamp = try FileStamp.read(url)
            return FileRecord(id: UUID(), url: url, root: originals, size: stamp.size, modified: stamp.modified, isProject: false, sensitive: false, vector: nil)
        }
        let cleanup = CleanupService(directory: base.appendingPathComponent("CleanupData"))
        let review = try await cleanup.preview(files: records, scope: originals)
        checkTrue(review.files.isEmpty); checkEqual(review.skipped, 2)
        checkEqual(try Data(contentsOf: first), bytes); checkEqual(try Data(contentsOf: second), bytes)
    }
    static func fileEvents() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesEvents-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let observed = ObservedFileEvents()
        let watcher = FileEventWatcher { urls, _ in Task { await observed.add(urls) } }
        checkTrue(watcher.start(roots: [base])); defer { watcher.stop() }
        let file = base.appendingPathComponent("watcher-probe.txt")
        try "Event fixture".write(to: file, atomically: true, encoding: .utf8)
        for _ in 0..<100 {
            if await observed.names.contains(file.lastPathComponent) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        failCheck("FSEvents did not deliver a created-file notification")
    }
    static func readOnlySafety() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesSafety-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Originals")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixtures: [String: Data] = ["notes.txt": Data("Australian government project notes".utf8), "draft.bin": Data([0, 1, 255, 7]), "invoice.csv": Data("item,price\npaper,10".utf8)]
        for (name, bytes) in fixtures { try bytes.write(to: root.appendingPathComponent(name)) }
        let dates = try fixtures.keys.reduce(into: [String: Date]()) { values, name in values[name] = try root.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let library = FileLibrary(directory: base.appendingPathComponent("Data"), embeddingFactory: { NoNavigationEmbedding() })
        _ = try await library.load(); try await library.addRoot(root); _ = try await library.scan()
        for query in ["government", "delete everything", "move all files to trash", "organize all files", "restore previous version", "recent files grouped by kind"] {
            _ = library.searchCatalog.matches(query); _ = await library.searchMatches(query)
            _ = try await library.saveSmartCollection(query)
        }
        _ = try await library.synchronizeChanges(fixtures.keys.map { root.appendingPathComponent($0) })
        do { try await library.setAutoOrganize(true); failCheck("Unattended file moves must remain disabled") } catch {}
        let state = await library.current(); checkFalse(state.autoOrganize)
        checkEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(fixtures.keys))
        for (name, bytes) in fixtures {
            let url = root.appendingPathComponent(name)
            checkEqual(try Data(contentsOf: url), bytes)
            checkEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, dates[name])
        }
    }
    static func queryPlans() async throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1781611200)
        let plan = NavigationQuery("PDFs in Downloads this month grouped by kind", now: now, calendar: calendar)
        checkEqual(NavigationQuery("file.pdf").topic.terms, ["file", "pdf"])
        checkEqual(plan.extensions, ["pdf"]); checkEqual(plan.location, "downloads"); checkEqual(plan.grouping, .kind)
        checkTrue(plan.topic.terms.isEmpty); checkTrue(plan.after != nil)
        let root = URL(fileURLWithPath: "/Synthetic/Downloads")
        let file = FileRecord(id: UUID(), url: root.appendingPathComponent("ATO notice.pdf"), root: root, size: 100, modified: now, isProject: false, sensitive: false, vector: nil, searchTerms: ["australian", "government", "taxation"])
        let other = FileRecord(id: UUID(), url: root.appendingPathComponent("photo.jpg"), root: root, size: 100, modified: now, isProject: false, sensitive: false, vector: nil, searchTerms: [])
        checkTrue(plan.accepts(file)); checkFalse(plan.accepts(other))
        let catalog = SearchCatalog(); catalog.replace([file, other])
        checkEqual(catalog.matches("pdfs in Downloads this month", now: now).count, 1)
        checkEqual(catalog.matches("govern", now: now).first?.file.id, file.id)
        checkEqual(catalog.matches("all my files", now: now).count, 2)
        checkEqual(catalog.matches("images in Downloads", now: now).first?.file.id, other.id)
        checkTrue(catalog.matches("pdfs in Documents", now: now).isEmpty)
        let old = NavigationQuery("PDFs last month", now: now, calendar: calendar)
        checkTrue(old.before != nil); checkTrue(old.after != nil)
    }
    static func persistentSync() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesNavigation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Downloads"), data = base.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let letter = root.appendingPathComponent("letter.txt")
        try "Australian government correspondence about a licence.".write(to: letter, atomically: true, encoding: .utf8)
        let library = FileLibrary(directory: data, embeddingFactory: { NoNavigationEmbedding() })
        _ = try await library.load(); try await library.addRoot(root); _ = try await library.scan()
        let initialRevision = library.searchCatalog.revision
        checkEqual(library.searchCatalog.matches("government").count, 1)
        let groups = try await library.saveSmartCollection("government files grouped by folder")
        checkEqual(groups.count, 1)
        let restart = FileLibrary(directory: data, embeddingFactory: { NoNavigationEmbedding() })
        let loaded = try await restart.load(); checkEqual(loaded.smartCollections?.count, 1)
        // Content is removed before querying: cached postings still answer without opening the file.
        try FileManager.default.removeItem(at: letter)
        checkEqual(restart.searchCatalog.matches("government").count, 1)
        _ = try await restart.synchronizeChanges([letter])
        checkTrue(restart.searchCatalog.matches("government").isEmpty)
        try "Australian government correspondence updated.".write(to: letter, atomically: true, encoding: .utf8)
        _ = try await restart.synchronizeChanges([letter])
        checkEqual(restart.searchCatalog.matches("government").count, 1)
        try "A music studio recording arrangement.".write(to: letter, atomically: true, encoding: .utf8)
        _ = try await restart.synchronizeChanges([letter])
        checkTrue(restart.searchCatalog.matches("government").isEmpty)
        checkEqual(restart.searchCatalog.matches("recording").count, 1)
        let renamed = root.appendingPathComponent("session.txt")
        try FileManager.default.moveItem(at: letter, to: renamed)
        _ = try await restart.synchronizeChanges([letter, renamed])
        checkEqual(restart.searchCatalog.matches("recording").first?.file.url.lastPathComponent, renamed.lastPathComponent)
        checkTrue(restart.searchCatalog.matches("letter").isEmpty)
        checkTrue(library.searchCatalog.revision >= initialRevision)
        let outside = base.appendingPathComponent("outside.txt")
        try "Government outside the configured scope".write(to: outside, atomically: true, encoding: .utf8)
        _ = try await restart.synchronizeChanges([outside])
        checkTrue(restart.searchCatalog.matches("government").isEmpty)
        try FileManager.default.removeItem(at: renamed)
        try FileManager.default.createSymbolicLink(at: renamed, withDestinationURL: outside)
        _ = try await restart.synchronizeChanges([renamed])
        checkTrue(restart.searchCatalog.matches("recording").isEmpty)
        let saved = try await restart.removeSmartCollection(groups[0].id); checkTrue(saved.isEmpty)
    }
}
