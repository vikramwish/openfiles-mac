import Foundation
import NaturalLanguage
import PDFKit

/// Serializes filesystem operations off the UI thread. No cloud services or API credentials.
public actor FileLibrary {
    public let directory: URL
    var state = LibraryState()
    private var proposals: [MoveProposal] = []
    var semanticOrganizationPlan: OrganizationPreview?
    var semanticOrganizationGeneration = UUID()
    private var discoveryRoots: [URL] = []
    private let fm = FileManager.default
    public nonisolated let searchCatalog = SearchCatalog()
    public nonisolated let indexMonitor = IndexMonitor()
    private let objects: EmbeddingObjects
    private var embeddingFactory: @Sendable () -> any EmbeddingBackend
    var queryBackend: any EmbeddingBackend
    private var embeddingGeneration = UUID()
    private var queryCache: [String: [Double]] = [:]
    private var scanRunning = false
    private var control: IndexControl?
    private var phaseBeforePause: IndexProgress.Phase = .indexing
    public init(directory: URL, embeddingFactory: @escaping @Sendable () -> any EmbeddingBackend = { NativeEmbeddingBackend() }) {
        self.directory = directory.canonical
        self.objects = EmbeddingObjects(directory: directory.canonical.appendingPathComponent("IndexObjects", isDirectory: true))
        self.embeddingFactory = embeddingFactory; self.queryBackend = embeddingFactory()
    }
    private var manifest: URL { directory.appendingPathComponent("library.json") }

    public func load() async throws -> LibraryState {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: manifest.path) { state = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: manifest)) }
        for index in state.files.indices {
            if let meta = state.files[index].indexMetadata, let key = meta.objectKey {
                state.files[index].vector = await objects.lookup(key, engine: meta.engine)?.vector
            }
        }
        searchCatalog.replace(state.files)
        if let report = state.lastIndexReport { indexMonitor.publish(report) }
        return state
    }
    public func current() -> LibraryState { state }
    /// Switch only between passes. Old objects remain reusable if the user switches back.
    public func setEmbeddingBackend(factory: @escaping @Sendable () -> any EmbeddingBackend) throws {
        guard !scanRunning else { throw OpenFilesError.message("Stop indexing before changing the search model.") }
        embeddingFactory = factory; queryBackend = factory(); embeddingGeneration = UUID()
        queryCache.removeAll()
        var progress = IndexProgress()
        progress.engine = queryBackend.displayName; progress.engineID = queryBackend.identifier
        progress.message = "Search model changed · check for changes to rebuild embeddings"
        indexMonitor.publish(progress)
    }
    func save() throws {
        try JSONEncoder().encode(state).write(to: manifest, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }
    /// Search scope is separate from explicit organization targets. Discovery never authorizes moves.
    public func enableDefaultDiscovery(home: URL) {
        let common = ["Downloads", "Documents", "Desktop", "Pictures", "Music", "Movies"].map { home.appendingPathComponent($0, isDirectory: true).canonical }
        discoveryRoots = common.filter { fm.fileExists(atPath: $0.path) } + [home.canonical]
    }
    public func addRoot(_ url: URL) throws {
        let root = url.canonical
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw OpenFilesError.message("Choose a folder.") }
        guard !FileRules.contains(root, directory), !FileRules.contains(directory, root) else { throw OpenFilesError.message("Choose a folder outside OpenFiles app data.") }
        guard !state.roots.contains(where: { FileRules.contains($0, root) || FileRules.contains(root, $0) }) else { throw OpenFilesError.message("This folder overlaps a folder already in your library.") }
        state.roots.append(root)
        do { try save() } catch { state.roots.removeLast(); throw error }
    }
    public func removeRoot(_ root: URL) throws {
        state.roots.removeAll { $0 == root }; state.files.removeAll { $0.root == root }; searchCatalog.replace(state.files); proposals = []; try save()
    }
    public func setAutoOrganize(_ enabled: Bool) throws {
        guard !enabled else { throw OpenFilesError.message("Unattended organization is disabled. Preview and apply file moves manually.") }
        state.autoOrganize = false; try save()
    }
    public func authorized(_ url: URL) throws -> URL {
        let real = url.canonical
        guard state.roots.contains(where: { FileRules.contains($0, real) }), !FileRules.contains(directory, real) else { throw OpenFilesError.message("This file is outside the library.") }
        return real
    }
    private func extractedText(_ url: URL, size: Int64) -> String {
        guard size <= 5 * 1024 * 1024 else { return "" }
        if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
            return (0..<min(pdf.pageCount, 20)).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n").prefix(12000).description
        }
        guard FileRules.textExtensions.contains(url.pathExtension.lowercased()) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8).prefix(12000).description) ?? ""
    }
    public func configureIndexing(_ settings: IndexSettings) throws {
        var settings = settings
        settings.workers = min(4, max(1, settings.workers)); settings.maxFiles = max(0, settings.maxFiles)
        settings.excludedFolders = settings.excludedFolders.map(\.canonical)
        state.indexSettings = settings
        state.files.removeAll { file in settings.excludedFolders.contains { FileRules.contains($0, file.url.canonical) } }
        searchCatalog.replace(state.files)
        try save()
    }
    public func pauseIndexing(_ paused: Bool) throws {
        var settings = state.indexSettings ?? IndexSettings(); settings.paused = paused; state.indexSettings = settings
        control?.setPaused(paused)
        var progress = indexMonitor.snapshot()
        if paused && scanRunning { phaseBeforePause = progress.phase; progress.phase = .paused; progress.message = "Paused · in-flight files finish before workers wait" }
        else if scanRunning && progress.phase == .paused { progress.phase = phaseBeforePause; progress.message = "Resuming changed files" }
        indexMonitor.publish(progress); try save()
    }
    public func cancelIndexing() { control?.cancel() }
    public func waitForIndexingToStop() async {
        while scanRunning { try? await Task.sleep(for: .milliseconds(50)) }
    }
    public func indexingIsRunning() -> Bool { scanRunning }
    public func indexScopes() -> [URL] { state.roots + discoveryRoots }
    public func scan() async throws -> ScanReport {
        guard !scanRunning else { throw OpenFilesError.message("An indexing pass is already running.") }
        scanRunning = true
        let settings = state.indexSettings ?? IndexSettings(), control = IndexControl(paused: (state.indexSettings ?? IndexSettings()).paused)
        self.control = control
        defer { scanRunning = false; self.control = nil }
        let roots = state.roots + discoveryRoots, prior = state.files, appData = directory, objects = objects, factory = embeddingFactory, monitor = indexMonitor
        let job = Task.detached(priority: .utility) {
            try await IndexPipeline.run(roots: roots, prior: prior, appData: appData, settings: settings, objects: objects, factory: factory, control: control, monitor: monitor) { records, progress in
                try await self.receiveIndexCheckpoint(records, progress: progress)
            }
        }
        do {
            let result = try await withTaskCancellationHandler { try await job.value } onCancel: { control.cancel(); job.cancel() }
            let exclusions = (state.indexSettings ?? IndexSettings()).excludedFolders
            if result.complete { state.files = result.records.filter { file in !exclusions.contains { FileRules.contains($0.canonical, file.url.canonical) } } }
            searchCatalog.replace(state.files)
            state.lastIndexReport = result.progress.persistedSummary; proposals = []; try save()
            return ScanReport(state: state, skipped: result.progress.skipped, embeddingsAvailable: result.progress.modelAvailable, progress: result.progress)
        } catch {
            var progress = indexMonitor.snapshot(); progress.phase = .failed; progress.finished = Date(); progress.message = error.localizedDescription
            indexMonitor.publish(progress)
            throw error
        }
    }

    private func receiveIndexCheckpoint(_ records: [FileRecord], progress: IndexProgress) throws {
        var merged = Dictionary(state.files.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
        let exclusions = (state.indexSettings ?? IndexSettings()).excludedFolders
        for file in records where !exclusions.contains(where: { FileRules.contains($0.canonical, file.url.canonical) }) { merged[file.url.standardizedFileURL.path] = file }
        state.files = merged.values.sorted { $0.url.path < $1.url.path }
        searchCatalog.upsert(records.filter { file in !exclusions.contains { FileRules.contains($0.canonical, file.url.canonical) } })
        state.lastIndexReport = progress.persistedSummary
        try save()
    }
    public func search(_ query: String) async -> [FileRecord] {
        await searchMatches(query).map(\.file)
    }
    public func searchMatches(_ input: String) async -> [FileSearchMatch] {
        let plan = NavigationQuery(input)
        guard !plan.isEmpty else { return [] }
        if plan.topic.terms.isEmpty { return searchCatalog.matches(input) }
        let q = plan.topic.text
        let backend = queryBackend, generation = embeddingGeneration
        let vector: [Double]?
        if let cached = queryCache[q] { vector = cached }
        else {
            vector = await backend.queryVector(for: q).map(VectorMath.normalized)
            guard generation == embeddingGeneration else { return [] }
            if let vector { if queryCache.count >= 32 { queryCache.removeAll(keepingCapacity: true) }; queryCache[q] = vector }
        }
        return searchCatalog.matches(input, vector: vector, engine: backend.identifier)
    }
    public func saveSmartCollection(_ query: String) throws -> [SmartCollection] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !NavigationQuery(query).isEmpty else { return state.smartCollections ?? [] }
        var groups = state.smartCollections ?? []
        if !groups.contains(where: { $0.query.localizedCaseInsensitiveCompare(query) == .orderedSame }) { groups.append(SmartCollection(query: query)) }
        state.smartCollections = groups; try save(); return groups
    }
    public func removeSmartCollection(_ id: UUID) throws -> [SmartCollection] {
        state.smartCollections?.removeAll { $0.id == id }; try save(); return state.smartCollections ?? []
    }
    func reconcileChanges(_ changed: [URL]) async throws -> LibraryState {
        let settings = state.indexSettings ?? IndexSettings()
        guard !scanRunning, !settings.paused else { throw OpenFilesError.message("Index is busy or paused; changes remain queued.") }
        scanRunning = true
        let control = IndexControl(); self.control = control
        defer { scanRunning = false; self.control = nil }
        let scopes = (state.roots + discoveryRoots).map(stableChangeURL), appData = stableChangeURL(directory)
        let prior = Dictionary(state.files.map { (stableChangeURL($0.url).path, $0) }, uniquingKeysWith: { first, _ in first })
        let worker = IndexWorker(backend: embeddingFactory(), objects: objects)
        let job = Task.detached(priority: .utility) {
            var paths = Set<String>(), candidates: [URL] = []
            func add(_ url: URL) {
                guard FileSearchQuery.allows(url), !syncContains(appData, url), !settings.excludedFolders.contains(where: { syncContains(stableChangeURL($0), url) }) else { return }
                guard scopes.contains(where: { syncContains($0, url) }), paths.insert(url.path).inserted else { return }
                var ancestor = url.deletingLastPathComponent()
                while scopes.contains(where: { syncContains($0, ancestor) }) {
                    if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent("pyvenv.cfg").path) { return }
                    if ancestor.path == "/" { break }; ancestor.deleteLastPathComponent()
                }
                if FileManager.default.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path) { return }
                candidates.append(url)
                if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true,
                   let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    for child in children { add(child) }
                }
            }
            for url in changed { add(stableChangeURL(url)) }
            var updates: [FileRecord] = [], removals = Set<String>()
            for url in candidates {
                try await control.checkpoint()
                var directory: ObjCBool = false
                if !FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) {
                    for path in prior.keys where syncContains(url, URL(fileURLWithPath: path)) { removals.insert(path); if let old = prior[path] { removals.insert(old.url.path) } }
                    continue
                }
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isPackageKey])
                if values.isSymbolicLink == true { for path in prior.keys where syncContains(url, URL(fileURLWithPath: path)) { removals.insert(path); if let old = prior[path] { removals.insert(old.url.path) } }; continue }
                if directory.boolValue && values.isPackage != true { continue }
                guard let root = scopes.first(where: { syncContains($0, url) }) else { continue }
                let stamp = try FileStamp.read(url)
                let result = await worker.process(Candidate(url: url, root: root, stamp: stamp, project: directory.boolValue, prior: prior[url.path]), control: control)
                if let record = result.record { updates.append(record) }
                else { throw OpenFilesError.message("A changed file is still being written; sync will retry.") }
            }
            return (updates, removals)
        }
        let (updates, removals) = try await withTaskCancellationHandler { try await job.value } onCancel: { control.cancel(); job.cancel() }
        let exclusions = (state.indexSettings ?? IndexSettings()).excludedFolders
        var merged = Dictionary(state.files.filter { !removals.contains($0.url.path) }.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        for file in updates where !exclusions.contains(where: { syncContains($0.canonical, file.url) }) {
            if settings.maxFiles == 0 || merged[file.url.path] != nil || merged.count < settings.maxFiles { merged[file.url.path] = file }
        }
        state.files = merged.values.sorted { $0.url.path < $1.url.path }
        searchCatalog.upsert(updates.filter { merged[$0.url.path] != nil }, removing: removals)
        try save()
        return state
    }
    /// Compare saved bytes, including package contents, rather than modification dates.
    public func versionStatus(_ input: URL) throws -> String {
        let source = input.canonical
        guard let latest = state.versions.first(where: { $0.source == source }) else { return "No committed versions" }
        return try FileIntegrity.digest(source) == latest.digest ? "All saved changes committed" : "Saved changes to commit"
    }
    public func versions(for input: URL) -> [FileVersion] {
        state.versions.filter { $0.source == input.canonical }.sorted { $0.created > $1.created }
    }
    public func commit(_ input: URL, message: String) throws -> LibraryState {
        try captureVersion(source: input.canonical, contents: input.canonical, message: message)
        return state
    }
    func checkSnapshotEligibility(_ url: URL) throws {
        let v = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
        guard v.isSymbolicLink != true else { throw OpenFilesError.message("Projects containing symbolic links are not supported yet.") }
        guard !FileRules.sensitive(url.lastPathComponent) else { throw OpenFilesError.message("Potentially sensitive files are excluded from version history. Use the encrypted vault.") }
        if v.isDirectory == true {
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try checkSnapshotEligibility(child) }
        } else if FileRules.sensitive(extractedText(url, size: Int64(v.fileSize ?? 0))) {
            throw OpenFilesError.message("Potentially sensitive content detected. Use the encrypted vault.")
        }
    }
    public func exportVersion(_ version: FileVersion, into folder: URL) throws -> URL {
        guard let version = state.versions.first(where: { $0.id == version.id }) else { throw OpenFilesError.message("Version not found.") }
        let source = directory.appendingPathComponent("Versions/\(version.id.uuidString)/\(version.name)")
        guard try FileIntegrity.digest(source) == version.digest else { throw OpenFilesError.message("Snapshot integrity check failed.") }
        let base = version.source.deletingPathExtension().lastPathComponent
        let suffix = version.source.pathExtension.isEmpty ? "" : ".\(version.source.pathExtension)"
        let target = folder.appendingPathComponent("\(base) restored \(version.id.uuidString.prefix(8))\(suffix)")
        // copyItem refuses existing destinations. Restoring never replaces the working file.
        try fm.copyItem(at: source, to: target)
        do {
            guard try FileIntegrity.digest(target) == version.digest else { throw OpenFilesError.message("Restored copy integrity check failed.") }
        } catch { try? fm.removeItem(at: target); throw error }
        return target
    }
    public func previewOrganization() throws -> [MoveProposal] {
        proposals = []
        for file in state.files where state.roots.contains(where: { $0.canonical.path == file.root.canonical.path }) && !file.sensitive && !file.isProject && file.url.deletingLastPathComponent().canonical.path == file.root.canonical.path && Date().timeIntervalSince(file.modified) > 10 {
            let source = try authorized(file.url)
            proposals.append(MoveProposal(id: file.id, source: source, destination: file.root.appendingPathComponent("Organized/\(file.category)/\(file.name)"), digest: try FileIntegrity.digest(source)))
        }
        return proposals
    }
    private func createOrganizationDirectory(_ parent: URL) throws {
        guard let root = state.roots.first(where: { FileRules.contains($0, parent) }) else { throw OpenFilesError.message("Invalid destination.") }
        let relative = String(parent.path.dropFirst(root.path.count)).split(separator: "/")
        var current = root
        for component in relative {
            current.appendPathComponent(String(component), isDirectory: true)
            if fm.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isDirectory == true, current.canonical.path == current.standardizedFileURL.path else { throw OpenFilesError.message("Destination contains a symbolic link or non-folder.") }
            } else { try fm.createDirectory(at: current, withIntermediateDirectories: false) }
        }
    }
    public func applyOrganization() async throws -> OrganizationReport {
        let plan = proposals; proposals = []; var report = OrganizationReport()
        for move in plan {
            do {
                let source = try authorized(move.source)
                guard try FileIntegrity.digest(source) == move.digest else { throw OpenFilesError.message("Changed since preview; skipped.") }
                // Re-check sensitive content so a changed classification cannot bypass protection.
                try checkSnapshotEligibility(source)
                let parent = move.destination.deletingLastPathComponent()
                try createOrganizationDirectory(parent)
                guard try authorized(parent).path == parent.standardizedFileURL.path else { throw OpenFilesError.message("Destination contains a symbolic link.") }
                try fm.copyItem(at: source, to: move.destination)
                guard try FileIntegrity.digest(source) == move.digest, try FileIntegrity.digest(move.destination) == move.digest else { throw OpenFilesError.message("Changed during move; source retained.") }
                try fm.removeItem(at: source); report.moved += 1
            } catch { report.errors.append("\(move.source.lastPathComponent): \(error.localizedDescription)") }
        }
        // Refresh the semantic catalog only when a pass is not already running.
        if !scanRunning { _ = try await scan() }; return report
    }
}
