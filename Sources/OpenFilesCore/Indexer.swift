import Foundation
import NaturalLanguage

struct Candidate: Sendable {
    let url: URL
    let root: URL
    let stamp: FileStamp
    let project: Bool
    let prior: FileRecord?
}
struct WorkResult: Sendable {
    var record: FileRecord?
    var event: IndexEvent
    var statHit = false
    var objectHit = false
    var embedded = false
    var extracted = false
    var tokenized = false
    var wordUnits = 0
    var bytes: Int64 = 0
    var extractionSeconds = 0.0
    var tokenizationSeconds = 0.0
    var embeddingSeconds = 0.0
    var skipReason: String?
}

actor IndexWorker {
    let backend: any EmbeddingBackend
    let objects: EmbeddingObjects
    init(backend: any EmbeddingBackend, objects: EmbeddingObjects) { self.backend = backend; self.objects = objects }
    func process(_ item: Candidate, control: IndexControl) async -> WorkResult {
        var result = WorkResult(event: IndexEvent(path: item.url.path, outcome: "Pending", detail: ""))
        do {
            try await control.checkpoint()
            guard try FileStamp.read(item.url) == item.stamp else { throw OpenFilesError.message("File changed after discovery") }
            let imageNeedsRefresh = NativeImageContent.extensions.contains(item.url.pathExtension.lowercased()) && item.prior?.sensitive != true && item.prior?.indexMetadata?.imageRevision != NativeImageContent.revision
            if var prior = item.prior, !imageNeedsRefresh, prior.searchTerms != nil, let meta = prior.indexMetadata, meta.stamp == item.stamp, meta.engine == backend.identifier, !meta.retryable, (prior.vector != nil || prior.sensitive || meta.imageRevision != nil) {
                prior.url = item.url; prior.root = item.root
                result.record = prior; result.statHit = true
                result.event.outcome = "Unchanged"; result.event.detail = "Stat cache hit: no content read, tokenization, or inference"
                if prior.sensitive { result.skipReason = "Sensitive content" }
                return result
            }
            var record = FileRecord(id: item.prior?.id ?? UUID(), url: item.url, root: item.root, size: item.stamp.size, modified: item.stamp.modified, isProject: item.project, sensitive: FileRules.sensitive(item.url.lastPathComponent), vector: nil)
            var text = ExtractedText(detail: "Filename only: project package")
            var retryable = false
            if !record.sensitive && !item.project {
                let start = Date()
                do { text = try IndexText.extract(item.url, size: item.stamp.size) }
                catch { retryable = true; text.detail = "Filename only: content could not be read; retry on next pass" }
                result.extractionSeconds = Date().timeIntervalSince(start); result.extracted = text.read; result.bytes = text.bytes
                retryable = retryable || text.detail.contains("cloud file") || text.detail.contains("locked or unreadable")
                record.sensitive = FileRules.sensitive(text.text)
            }
            guard try FileStamp.read(item.url) == item.stamp else { throw OpenFilesError.message("File changed during extraction") }
            if record.sensitive {
                record.searchTerms = []
                record.indexMetadata = FileIndexMetadata(stamp: item.stamp, engine: backend.identifier, objectKey: nil, wordUnits: 0, inputCharacters: 0, outcome: "Sensitive", detail: "Excluded from semantic embeddings by filename/content heuristic", retryable: false)
                result.record = record; result.skipReason = "Sensitive content"; result.event.outcome = "Sensitive"; result.event.detail = "Excluded from embeddings; file is not encrypted"
                return result
            }
            if text.read && text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text.detail = "Filename only: no extractable text" }
            record.imageContent = text.imageContent
            record.searchTerms = Array(Set(FileSearchQuery.words(text.text).prefix(6000))).sorted()
            let input = IndexText.prepare(text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.url.lastPathComponent : text.text)
            let key = IndexText.key(input, engine: backend.identifier), backend = self.backend
            let (object, cached) = try await objects.resolve(key, engine: backend.identifier) {
                let tokenStart = Date()
                let tokenizer = NLTokenizer(unit: .word); tokenizer.string = input
                var words = 0
                tokenizer.enumerateTokens(in: input.startIndex..<input.endIndex) { _, _ in words += 1; return true }
                let tokenSeconds = Date().timeIntervalSince(tokenStart)
                let start = Date(), vector = await backend.vector(for: input)
                return EmbeddingObject(engine: backend.identifier, vector: vector.map(VectorMath.normalized), wordUnits: words, inputCharacters: input.count, tokenizationSeconds: tokenSeconds, embeddingSeconds: Date().timeIntervalSince(start))
            }
            try Task.checkCancellation()
            guard try FileStamp.read(item.url) == item.stamp else { throw OpenFilesError.message("File changed during inference") }
            record.vector = object.vector
            let outcome = object.vector == nil ? "Model unavailable" : cached ? "Content reused" : "Embedded"
            record.indexMetadata = FileIndexMetadata(stamp: item.stamp, engine: backend.identifier, objectKey: object.vector == nil ? nil : key, wordUnits: object.wordUnits, inputCharacters: object.inputCharacters, outcome: outcome, detail: text.detail, retryable: retryable)
            if NativeImageContent.extensions.contains(item.url.pathExtension.lowercased()) { record.indexMetadata?.imageRevision = NativeImageContent.revision }
            result.record = record; result.objectHit = cached && object.vector != nil; result.tokenized = !cached
            result.embedded = !cached && object.vector != nil
            if !cached { result.wordUnits = object.wordUnits; result.tokenizationSeconds = object.tokenizationSeconds; result.embeddingSeconds = object.embeddingSeconds }
            if object.vector == nil { result.skipReason = "Model unavailable" }
            result.event.outcome = outcome
            result.event.detail = object.vector == nil ? "Model returned no vector; filename/content search remains available and a later pass can retry" : cached ? "Content-addressed object reused; no tokenization or inference" : text.detail
            if object.vector == nil, let reason = await backend.failureReason() { result.event.detail = reason }
        } catch is CancellationError { result.skipReason = "Cancelled"; result.event.outcome = "Cancelled"; result.event.detail = "Unfinished file will be retried" }
        catch { result.skipReason = "Changed or unreadable file"; result.event.outcome = "Skipped"; result.event.detail = error.localizedDescription }
        return result
    }
}

struct IndexResult: Sendable { var records: [FileRecord]; var progress: IndexProgress; var complete: Bool }

enum IndexPipeline {
    static let excludedNames: Set<String> = ["node_modules", "library", "build", "dist", "__pycache__", "pods", "carthage", "vendor", "venv", "env", "site-packages", "dist-packages", "deriveddata", "target"]
    static func run(roots: [URL], prior: [FileRecord], appData: URL, settings: IndexSettings, objects: EmbeddingObjects, factory: @Sendable () -> any EmbeddingBackend, control: IndexControl, monitor: IndexMonitor, checkpoint: @escaping @Sendable ([FileRecord], IndexProgress) async throws -> Void) async throws -> IndexResult {
        let workerCount = min(max(settings.workers, 1), min(4, ProcessInfo.processInfo.activeProcessorCount))
        let actualWorkers = ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : workerCount
        let backends = (0..<actualWorkers).map { _ in factory() }
        let engine = backends[0].identifier
        var progress = IndexProgress(); progress.started = Date(); progress.phase = .discovering; progress.engineID = engine; progress.engine = backends[0].displayName; progress.workers = actualWorkers; progress.limit = settings.maxFiles
        var candidates: [Candidate] = [], visited = Set<String>(), seen = Set<String>()
        let old = Dictionary(prior.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
        var records: [FileRecord] = [], pending: [FileRecord] = []
        var active: [Int: String] = [:]
        var lastPublished = Date.distantPast, lastCheckpoint = Date()
        func publish(force: Bool = false) {
            guard force || Date().timeIntervalSince(lastPublished) >= 0.15 else { return }
            progress.elapsedSeconds = Date().timeIntervalSince(progress.started!)
            progress.activeSeconds = max(0, progress.elapsedSeconds - control.pausedSeconds)
            progress.activePaths = active.keys.sorted().compactMap { active[$0] }
            var shown = progress
            if control.isPaused && (progress.phase == .discovering || progress.phase == .indexing) { shown.phase = .paused; shown.message = "Paused · in-flight files finish before workers wait" }
            monitor.publish(shown); lastPublished = Date()
        }
        func event(_ url: URL, _ reason: String) {
            progress.skipReasons[reason, default: 0] += 1
            progress.events.insert(IndexEvent(path: url.path, outcome: "Skipped", detail: reason), at: 0)
            progress.events = Array(progress.events.prefix(100))
            publish()
        }
        func visit(_ folder: URL, root: URL) async throws {
            try await control.checkpoint()
            guard visited.insert(folder.canonical.path).inserted else { return }
            if FileRules.contains(appData, folder.canonical) { event(folder, "App data / vault"); return }
            if settings.excludedFolders.contains(where: { FileRules.contains($0.canonical, folder.canonical) }) { event(folder, "User exclusion"); return }
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("pyvenv.cfg").path) { event(folder, "Python virtual environment"); return }
            let children: [URL]
            do { children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isRegularFileKey], options: []) }
            catch { event(folder, "Permission denied or unavailable folder"); return }
            for url in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try await control.checkpoint()
                if settings.maxFiles > 0 && candidates.count >= settings.maxFiles { progress.limitReached = true; return }
                if url.lastPathComponent.hasPrefix(".") { event(url, "Hidden files / folders"); continue }
                if excludedNames.contains(url.lastPathComponent.lowercased()) || url.lastPathComponent.lowercased().hasSuffix(".dist-info") || url.lastPathComponent.lowercased().hasSuffix(".egg-info") { event(url, "Generated / system directory"); continue }
                if settings.excludedFolders.contains(where: { FileRules.contains($0.canonical, url.canonical) }) { event(url, "User exclusion"); continue }
                do {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isRegularFileKey])
                    if values.isSymbolicLink == true { event(url, "Symbolic link"); continue }
                    let project = values.isDirectory == true && (values.isPackage == true || FileRules.packageExtensions.contains(url.pathExtension.lowercased()))
                    if values.isDirectory == true && !project { try await visit(url, root: root); continue }
                    guard values.isRegularFile == true || project else { event(url, "Unsupported filesystem item"); continue }
                    guard !FileRules.contains(appData, url.canonical), seen.insert(url.canonical.path).inserted else { continue }
                    let stamp = try FileStamp.read(url)
                    candidates.append(Candidate(url: url, root: root, stamp: stamp, project: project, prior: old[url.standardizedFileURL.path]))
                    progress.discovered = candidates.count; progress.currentPath = url.path; progress.message = "Discovering files"; publish()
                } catch is CancellationError { throw CancellationError() }
                catch { event(url, "Permission denied or unavailable file") }
            }
        }
        do {
            publish(force: true)
            for root in roots {
                if settings.maxFiles > 0 && candidates.count >= settings.maxFiles { progress.limitReached = true; break }
                try await visit(root, root: root)
            }
            progress.phase = .indexing; progress.message = "Processing changed files"; publish(force: true)
            let workers = backends.map { IndexWorker(backend: $0, objects: objects) }
            await withTaskGroup(of: (Int, WorkResult).self) { group in
                var next = 0
                for worker in workers.indices where next < candidates.count {
                    let candidate = candidates[next]; next += 1
                    active[worker] = candidate.url.path
                    group.addTask { (worker, await workers[worker].process(candidate, control: control)) }
                }
                publish(force: true)
                while let (worker, result) = await group.next() {
                    active[worker] = nil
                    progress.processed += 1
                    if let file = result.record { records.append(file); pending.append(file); progress.modelAvailable = progress.modelAvailable || file.vector != nil }
                    progress.statHits += result.statHit ? 1 : 0; progress.objectHits += result.objectHit ? 1 : 0
                    progress.embedded += result.embedded ? 1 : 0; progress.extracted += result.extracted ? 1 : 0; progress.tokenized += result.tokenized ? 1 : 0
                    progress.wordUnits += result.wordUnits; progress.bytesRead += result.bytes
                    progress.extractionSeconds += result.extractionSeconds; progress.tokenizationSeconds += result.tokenizationSeconds; progress.embeddingSeconds += result.embeddingSeconds
                    if let reason = result.skipReason { progress.skipReasons[reason, default: 0] += 1 }
                    progress.currentPath = result.event.path; progress.events.insert(result.event, at: 0); progress.events = Array(progress.events.prefix(100)); publish()
                    if pending.count >= 128 || (!pending.isEmpty && Date().timeIntervalSince(lastCheckpoint) > 5) {
                        do { progress.checkpointed += pending.count; try await checkpoint(pending, progress); pending = []; lastCheckpoint = Date() }
                        catch { control.cancel(); progress.message = "Checkpoint failed: \(error.localizedDescription)"; progress.phase = .failed }
                    }
                    if control.isCancelled || Task.isCancelled { group.cancelAll() }
                    else if next < candidates.count {
                        let candidate = candidates[next]; next += 1
                        active[worker] = candidate.url.path
                        group.addTask { (worker, await workers[worker].process(candidate, control: control)) }
                    }
                }
            }
        } catch is CancellationError { control.cancel() }
        if progress.phase != .failed { progress.phase = control.isCancelled || Task.isCancelled ? .cancelled : .completed }
        progress.finished = Date(); progress.checkpointed = records.count
        progress.message = progress.phase == .completed ? (progress.limitReached ? "Pass complete · semantic file limit reached" : "Index is up to date") : progress.phase == .cancelled ? "Stopped · completed work saved; resume with another pass" : progress.message
        publish(force: true)
        try await checkpoint(pending, progress)
        return IndexResult(records: records, progress: monitor.snapshot(), complete: progress.phase == .completed)
    }
}
