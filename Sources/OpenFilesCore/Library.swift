import Foundation
import NaturalLanguage
import PDFKit

/// Serializes filesystem operations off the UI thread. No cloud services or API credentials.
public actor FileLibrary {
    public let directory: URL
    private var state = LibraryState()
    private var proposals: [MoveProposal] = []
    private var discoveryRoots: [URL] = []
    private let fm = FileManager.default
    public nonisolated let indexMonitor = IndexMonitor()
    private let objects: EmbeddingObjects
    private var embeddingFactory: @Sendable () -> any EmbeddingBackend
    private var queryBackend: any EmbeddingBackend
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
        if let report = state.lastIndexReport, report.engineID == queryBackend.identifier { indexMonitor.publish(report) }
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
    private func save() throws {
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
        state.roots.removeAll { $0 == root }; state.files.removeAll { $0.root == root }; proposals = []; try save()
    }
    public func setAutoOrganize(_ enabled: Bool) throws { state.autoOrganize = enabled; try save() }
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
        state.lastIndexReport = progress.persistedSummary
        try save()
    }
    public func search(_ query: String) async -> [FileRecord] {
        await searchMatches(query).map(\.file)
    }
    public func searchMatches(_ input: String) async -> [FileSearchMatch] {
        let query = FileSearchQuery(input)
        guard !query.terms.isEmpty else { return [] }
        // Preserve natural-language meaning for retrieval models. Lexical matching still
        // uses FileSearchQuery's grouped terms and evidence requirements below.
        let q = IndexText.prepare(input)
        let queryBackend = self.queryBackend, generation = embeddingGeneration
        let vector: [Double]?
        if let cached = queryCache[q] { vector = cached }
        else {
            vector = await queryBackend.queryVector(for: q).map(VectorMath.normalized)
            guard generation == embeddingGeneration else { return [] }
            if let vector { if queryCache.count >= 32 { queryCache.removeAll(keepingCapacity: true) }; queryCache[q] = vector }
        }
        let candidates = state.files.filter { FileSearchQuery.allows($0.url) && !FileRules.contains(directory, $0.url.canonical) }.map { file -> (FileRecord, Double) in
            let compatible = file.indexMetadata.map { $0.engine == queryBackend.identifier } ?? queryBackend.acceptsLegacyVectors
            let similarity = !file.sensitive && compatible ? vector.flatMap { v in file.vector.map { file.indexMetadata == nil ? VectorMath.cosine(v, $0) : VectorMath.dot(v, $0) } } ?? 0 : 0
            return (file, similarity)
        }.sorted {
            let left = query.coverage(in: $0.0.name), right = query.coverage(in: $1.0.name)
            return left == right ? $0.1 > $1.1 : left > right
        }
        // Bound content reads and keep PDF/text extraction off the library actor and main thread.
        let job = Task.detached(priority: .userInitiated) {
            var matches: [FileSearchMatch] = []
            for (file, similarity) in candidates.prefix(240) {
                if Task.isCancelled { break }
                var content = ""
                if !file.sensitive, let extracted = try? IndexText.extract(file.url, size: file.size), !FileRules.sensitive(extracted.text) { content = extracted.text }
                guard let score = query.score(name: file.name, content: content, similarity: similarity) else { continue }
                let reason = query.coverage(in: file.name) == 1 ? "Filename matches" : "Document text matches"
                matches.append(FileSearchMatch(file: file, score: score, reason: reason))
            }
            return matches.sorted { $0.score == $1.score ? $0.file.url.path < $1.file.url.path : $0.score > $1.score }
        }
        let matches = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        return generation == embeddingGeneration ? matches : []
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
        let source = input.canonical
        guard !FileRules.contains(directory, source), !FileRules.contains(source, directory) else { throw OpenFilesError.message("OpenFiles app data cannot be versioned.") }
        try checkSnapshotEligibility(source)
        let version = FileVersion(id: UUID(), source: source, message: message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Saved version" : String(message.prefix(500)), created: Date(), digest: try FileIntegrity.digest(source))
        let folder = directory.appendingPathComponent("Versions/\(version.id.uuidString)")
        let payload = folder.appendingPathComponent(source.lastPathComponent)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            // Full copies preserve opaque binary formats and project packages. Save in the editor first.
            try fm.copyItem(at: source, to: payload)
            guard try FileIntegrity.digest(source) == version.digest, try FileIntegrity.digest(payload) == version.digest else { throw OpenFilesError.message("The file changed during the snapshot. Save in your editor, then retry.") }
            state.versions.insert(version, at: 0)
            do { try save() } catch { state.versions.removeFirst(); throw error }
        } catch { try? fm.removeItem(at: folder); throw error }
        return state
    }
    private func checkSnapshotEligibility(_ url: URL) throws {
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
