import AppKit
import Photos
import CryptoKit
import ImageIO
import OpenFilesCore

struct LibraryPhoto: Identifiable {
    let id: String
    let name: String
    let date: Date?
    let favorite: Bool
    let url: URL?
    let asset: PHAsset?
    var terms: [String]
    var albums: [String] = []
    var isScreenshot: Bool = false
}

private final class PhotoResourceHash: @unchecked Sendable {
    private let lock = NSLock()
    private var hash = SHA256()
    private var bytes: Int64 = 0
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; hash.update(data: data); bytes += Int64(data.count) }
    func finish(kind: String) -> PhotoResourceFingerprint {
        lock.lock(); defer { lock.unlock() }
        return .init(kind: kind, digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes)
    }
}

enum PhotoReviewMode: String { case all, duplicates, similar, screenshots }
enum PhotoSimilarityScope: String, CaseIterable {
    case veryClose = "Very close", broader = "Broader matches"
    var radius: Float { self == .veryClose ? 0.25 : 0.40 }
}

@MainActor
final class PhotoLibraryModel: ObservableObject {
    @Published private(set) var items: [LibraryPhoto] = []
    @Published private(set) var groups: [PhotoDuplicateGroup] = []
    @Published private(set) var similarGroups: [PhotoSimilarityGroup] = []
    @Published private(set) var screenshotSuggestions: [String: ScreenshotAssessment] = [:]
    private var screenshotFingerprints: [String: PhotoFingerprint] = [:]
    private var screenshotRevisions: [String: Date] = [:]
    private var screenshotTerms: [String: [String]] = [:]
    private var reviewed: [String: PhotoFingerprint] = [:]
    @Published private(set) var connected = false
    @Published private(set) var archive: URL?
    @Published private(set) var busy = false
    @Published private(set) var status = "Connect your photos to browse, search, organize, and find duplicates here."
    @Published var error: String?
    @Published var selected = Set<String>()
    @Published var query = ""
    @Published var reviewMode: PhotoReviewMode = .all { didSet { if oldValue != reviewMode { selected = [] } } }
    @Published var similarityScope: PhotoSimilarityScope = .veryClose
    var duplicatesOnly: Bool {
        get { reviewMode == .duplicates }
        set { reviewMode = newValue ? .duplicates : .all }
    }
    var similarOnly: Bool { reviewMode == .similar }
    var screenshotsOnly: Bool { reviewMode == .screenshots }
    private struct CachedVisual {
        let stamp: FileStamp?
        let date: Date?
        let signature: PhotoVisualSignature
    }
    private var visualCache: [String: CachedVisual] = [:]
    @Published var allowDownloads = false
    @Published var albumName = ""
    private var job: Task<Void, Never>?
    private var revisions: [String: Date] = [:]
    private var analysis: [String: [String]] = [:]
    private var analysisRevisions: [String: Date] = [:]
    private var archiveAnalysisStamps: [String: FileStamp] = [:]
    var selectedItems: [LibraryPhoto] { items.filter { selected.contains($0.id) } }
    var visibleItems: [LibraryPhoto] {
        let duplicateIDs = Set(groups.flatMap { $0.items.map(\.id) })
        let similarIDs = Set(similarGroups.flatMap(\.photoIDs))
        let plan = NavigationQuery(query)
        let visible = items.filter { item in
            guard !duplicatesOnly || duplicateIDs.contains(item.id) else { return false }
            guard !similarOnly || similarIDs.contains(item.id) else { return false }
            guard !screenshotsOnly || screenshotSuggestions[item.id] != nil else { return false }
            if let after = plan.after, (item.date ?? .distantPast) < after { return false }
            if let before = plan.before, (item.date ?? .distantFuture) >= before { return false }
            let text = ([item.name, item.date?.formatted(date: .long, time: .omitted) ?? "", "photo photos picture pictures image images"] + item.terms).joined(separator: " ")
            let words = Set(FileSearchQuery.words(text))
            if let place = plan.photoLocation, !Set(FileSearchQuery.words(place)).isSubset(of: words) { return false }
            if let album = plan.location, !item.albums.contains(where: { $0.localizedCaseInsensitiveContains(album) }) { return false }
            return plan.topic.groups.allSatisfy { group in group.contains { alias in
                FileSearchQuery.words(alias).allSatisfy { word in words.contains { $0.hasPrefix(word) } }
            } }
        }
        if screenshotsOnly {
            return visible.sorted {
                let a = screenshotSuggestions[$0.id]?.score ?? 0, b = screenshotSuggestions[$1.id]?.score ?? 0
                return a == b ? ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) : a > b
            }
        }
        return visible
    }
    func selectExtraCopies() {
        guard duplicatesOnly else { return }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        selected = Set(groups.flatMap { group -> [String] in
            let ranked = group.items.sorted { lhs, rhs in
                let a = byID[lhs.id], b = byID[rhs.id]
                if a?.favorite != b?.favorite { return a?.favorite == true }
                if a?.date != b?.date { return (a?.date ?? .distantFuture) < (b?.date ?? .distantFuture) }
                return lhs.id < rhs.id
            }
            return ranked.dropFirst().map(\.id)
        })
        status = "Selected extra copies for your review. Favorites and earlier dates are preferred for the kept copy; no photos have been removed."
    }

    var canRemoveDuplicates: Bool {
        guard duplicatesOnly, !busy, archive == nil, connected else { return false }
        return (try? PhotoDuplicates.validate(selected, in: groups)) != nil
    }
    func connect() {
        run {
            guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil else {
                throw OpenFilesError.message("Open the bundled OpenFiles app to connect Photos. The command-line executable has no Photos permission description.")
            }
            let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard access == .authorized || access == .limited else {
                throw OpenFilesError.message("Photo access wasn’t granted. You can enable it for OpenFiles in System Settings → Privacy & Security → Photos, or choose a library for read-only inspection.")
            }
            self.archive = nil; self.connected = true
            try await self.reload()
        }
    }
    func refresh() {
        guard archive == nil else { if let archive { inspect(archive) }; return }
        run {
            let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard access == .authorized || access == .limited else { throw OpenFilesError.message("Photo access changed. Connect Photos again to refresh.") }
            try await self.reload()
        }
    }
    private func reload() async throws {
        let knownAnalysis = analysis, knownRevisions = analysisRevisions
        let loader = Task.detached(priority: .utility) { () throws -> [LibraryPhoto] in
            let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let fetched = PHAsset.fetchAssets(with: options)
            var albums: [String: [String]] = [:]
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { album, _, _ in
                guard let title = album.localizedTitle else { return }
                PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in albums[asset.localIdentifier, default: []].append(title) }
            }
            var photos: [LibraryPhoto] = []
            for index in 0..<fetched.count {
                try Task.checkCancellation()
                let asset = fetched.object(at: index)
                guard asset.mediaType == .image || asset.mediaType == .video else { continue }
                let resources = PHAssetResource.assetResources(for: asset)
                let memberAlbums = albums[asset.localIdentifier] ?? []
                var terms = knownRevisions[asset.localIdentifier] == (asset.modificationDate ?? .distantPast) ? knownAnalysis[asset.localIdentifier] ?? [] : []
                terms += memberAlbums
                if let location = asset.location { terms += PhotoMediaAnalysis.placeTerms(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude) }
                if asset.isFavorite { terms += ["favorite", "favourite"] }
                if asset.mediaType == .video { terms += ["video", "movie"] }
photos.append(.init(id: asset.localIdentifier, name: resources.first?.originalFilename ?? "Photo", date: asset.creationDate, favorite: asset.isFavorite, url: nil, asset: asset, terms: terms, albums: memberAlbums, isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)))
            }
            return photos
        }
        let photos = try await withTaskCancellationHandler { try await loader.value } onCancel: { loader.cancel() }
        try Task.checkCancellation()
items = photos; groups = []; reviewed = [:]; similarGroups = []; screenshotSuggestions = [:]; screenshotFingerprints = [:]; screenshotRevisions = [:]; screenshotTerms = [:]; revisions = [:]; selected = []
        let currentIDs = Set(photos.map(\.id)); visualCache = visualCache.filter { currentIDs.contains($0.key) }
        status = "\(photos.count) photos and videos available through macOS. Cloud-only originals may need downloading."
    }
    func chooseLibrary() {
        let panel = NSOpenPanel(); panel.title = "Inspect a Photos library"; panel.prompt = "Inspect library"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        inspect(url)
    }
    func inspect(_ url: URL) {
        run {
            let scanner = Task.detached(priority: .utility) {
                try await PhotoArchive.review(url) { count in
                    if count % 25 == 0 { await MainActor.run { self.status = "Checking local originals · \(count) read" } }
                }
            }
            let result = try await withTaskCancellationHandler { try await scanner.value } onCancel: { scanner.cancel() }
            try Task.checkCancellation()
self.archive = result.library; self.connected = true; self.groups = result.groups
            self.reviewed = Dictionary(result.groups.flatMap(\.items).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.similarGroups = []; self.screenshotSuggestions = [:]; self.screenshotFingerprints = [:]; self.screenshotRevisions = [:]; self.screenshotTerms = [:]
            self.items = result.photos.map { .init(id: $0.id, name: $0.url.lastPathComponent, date: $0.stamp.modified, favorite: false, url: $0.url, asset: nil, terms: self.archiveAnalysisStamps[$0.id] == $0.stamp ? self.analysis[$0.id] ?? [] : []) }
            let currentIDs = Set(self.items.map(\.id)); self.visualCache = self.visualCache.filter { currentIDs.contains($0.key) }
            self.selected = []; self.duplicatesOnly = !result.groups.isEmpty
            self.status = "\(result.photos.count) local originals · \(result.groups.count) duplicate groups · \(result.skipped) skipped. Read-only library inspection; edits and albums are available through Connect Photos."
        }
    }
    func findDuplicates() {
        if let archive { inspect(archive); return }
        let snapshot = items
        run {
            var prints: [PhotoFingerprint] = [], skipped = 0, dates: [String: Date] = [:]
            for (index, item) in snapshot.enumerated() {
                try Task.checkCancellation()
                self.status = "Checking originals · \(index + 1) of \(snapshot.count)"
                guard let asset = self.fetch(item.id) else { skipped += 1; continue }
                do {
                    let fingerprint = try await self.fingerprint(asset)
                    prints.append(fingerprint); dates[item.id] = asset.modificationDate ?? .distantPast
                } catch is CancellationError { throw CancellationError() }
                catch { skipped += 1 }
            }
            self.groups = PhotoDuplicates.groups(prints)
            self.revisions = dates; self.selected = []; self.duplicatesOnly = true
            self.status = "\(self.groups.count) exact duplicate groups · \(prints.count) fully checked · \(skipped) unavailable or changed. Edited resources and Live Photo components must also match."
        }
    }
    func findSimilar() {
        let snapshot = items, radius = similarityScope.radius
        run {
            var signatures: [String: PhotoVisualSignature] = [:], skipped = 0
            for (index, item) in snapshot.enumerated() {
                try Task.checkCancellation()
                self.status = "Comparing photo appearance · \(index + 1) of \(snapshot.count)"
                do {
                    let stamp: FileStamp?, date: Date?, asset: PHAsset?
                    if let url = item.url { stamp = try FileStamp.read(url); date = nil; asset = nil }
                    else {
                        guard let fresh = self.fetch(item.id), fresh.mediaType == .image else { skipped += 1; continue }
                        stamp = nil; date = fresh.modificationDate; asset = fresh
                    }
                    if let cached = self.visualCache[item.id], cached.stamp == stamp, cached.date == date {
                        signatures[item.id] = cached.signature; continue
                    }
                    let signature: PhotoVisualSignature
                    if let url = item.url {
                        let worker = Task.detached(priority: .utility) { try PhotoVisualAnalysis.signature(at: url) }
                        signature = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                        guard try FileStamp.read(url) == stamp else { skipped += 1; continue }
                    } else {
                        guard let asset, let image = await PhotoThumbnails.image(asset: asset, size: 1024, network: self.allowDownloads),
                              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { skipped += 1; continue }
                        let worker = Task.detached(priority: .utility) { try PhotoVisualAnalysis.signature(image: cgImage) }
                        signature = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                        guard self.fetch(item.id)?.modificationDate == date else { skipped += 1; continue }
                    }
                    try Task.checkCancellation()
                    signatures[item.id] = signature
                    self.visualCache[item.id] = CachedVisual(stamp: stamp, date: date, signature: signature)
                } catch is CancellationError { throw CancellationError() }
                catch { skipped += 1 }
            }
            self.status = "Grouping similar-looking photos…"
            let ready = signatures
            let worker = Task.detached(priority: .utility) {
                try PhotoSimilarity.groups(ids: Array(ready.keys), radius: radius) { a, b in
                    guard let first = ready[a], let second = ready[b] else { throw OpenFilesError.message("Visual description missing") }
                    return try first.distance(to: second)
                }
            }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            self.similarGroups = result; self.reviewMode = .similar; self.selected = []
            self.status = "\(result.count) similar-looking groups · \(signatures.count) photos compared · \(skipped) unavailable or unsupported. Visual similarity is a suggestion, not proof of a duplicate."
        }
    }
    func screenshotRemovalAvailable(_ id: String) -> Bool { screenshotFingerprints[id] != nil }
    var canRemoveScreenshots: Bool {
        screenshotsOnly && archive == nil && !busy && !selected.isEmpty && selected.allSatisfy { screenshotSuggestions[$0] != nil && screenshotFingerprints[$0] != nil }
    }
    func reviewScreenshots() {
        let snapshot = items
        run {
            let now = Date()
            var suggestions: [String: ScreenshotAssessment] = [:], prints: [String: PhotoFingerprint] = [:], dates: [String: Date] = [:], termsByID: [String: [String]] = [:]
            var unavailable = 0, analyzed = 0
            for (index, item) in snapshot.enumerated() {
                try Task.checkCancellation()
                guard !FileRules.sensitive(item.name) else { continue }
                self.status = "Reviewing older screenshots · \(index + 1) of \(snapshot.count)"
                let source: ScreenshotSource, modified: Date, created: Date?, lastUsed: Date?, kept: Bool, asset: PHAsset?
                if let url = item.url {
                    let metadata = SystemScreenshotMetadata().metadata(for: url)
                    guard let detected = ScreenshotReview.source(for: url, metadata: metadata), let stamp = try? FileStamp.read(url) else { continue }
                    source = detected; modified = stamp.modified; created = metadata.created; lastUsed = metadata.lastUsed; kept = !metadata.tags.isEmpty; asset = nil
                } else {
                    guard let current = self.fetch(item.id), current.mediaSubtypes.contains(.photoScreenshot) else { continue }
                    source = .photosMetadata; modified = current.modificationDate ?? current.creationDate ?? now
                    created = current.creationDate; lastUsed = nil; asset = current
                    kept = current.isFavorite || PHAssetCollection.fetchAssetCollectionsContaining(current, with: .album, options: nil).count > 0
                }
                var signals = ScreenshotSignals(source: source, created: created, modified: modified, lastUsed: lastUsed, kept: kept)
                guard ScreenshotReview.isOldUnkept(signals, now: now) else { continue }
                do { signals.contentTerms = try await self.readScreenshotTerms(item: item, asset: asset); analyzed += 1 }
                catch is CancellationError { throw CancellationError() }
                catch { unavailable += 1 }
                signals.hasNewerRelatedCapture = self.similarGroups.contains { group in
                    group.photoIDs.contains(item.id) && snapshot.contains { other in
                        other.isScreenshot && group.photoIDs.contains(other.id) && (other.date ?? .distantPast) > (item.date ?? .distantPast)
                    }
                }
                guard let assessment = ScreenshotReview.assess(signals, now: now) else { continue }
                if let asset {
                    do { prints[item.id] = try await self.fingerprint(asset); dates[item.id] = modified }
                    catch is CancellationError { throw CancellationError() }
                    catch { unavailable += 1 }
                }
                suggestions[item.id] = assessment
                if let terms = signals.contentTerms { termsByID[item.id] = terms }
            }
            try Task.checkCancellation()
            self.screenshotSuggestions = suggestions; self.screenshotFingerprints = prints; self.screenshotRevisions = dates; self.screenshotTerms = termsByID
            self.reviewMode = .screenshots; self.selected = []
            self.status = "\(suggestions.count) older screenshots to review · \(analyzed) contents analyzed · \(unavailable) checks unavailable. Favorites, albums, recent changes, and recognized records stay out. Viewing history is not available for Photos assets."
        }
    }
    private func readScreenshotTerms(item: LibraryPhoto, asset: PHAsset?) async throws -> [String] {
        let url: URL, temporary: Bool
        if let file = item.url { url = file; temporary = false }
        else {
            guard let asset, let image = await PhotoThumbnails.image(asset: asset, size: 1024, network: allowDownloads), let data = image.tiffRepresentation else {
                throw OpenFilesError.message("Screenshot contents unavailable")
            }
            url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesScreenshot-\(UUID()).tiff")
            try data.write(to: url, options: .atomic); temporary = true
        }
        defer { if temporary { try? FileManager.default.removeItem(at: url) } }
        let worker = Task.detached(priority: .utility) { try PhotoMediaAnalysis.terms(at: url) }
        let terms = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return terms
    }
    func removeReviewedScreenshots() {
        let ids = selected
        guard canRemoveScreenshots else { return }
        run {
            for id in ids {
                try Task.checkCancellation()
                guard let asset = self.fetch(id), asset.mediaSubtypes.contains(.photoScreenshot),
                      (asset.modificationDate ?? asset.creationDate ?? .distantPast) == self.screenshotRevisions[id],
                      let expected = self.screenshotFingerprints[id]?.signature else { throw OpenFilesError.message("Screenshot review is stale. Review screenshots again.") }
                let kept = asset.isFavorite || PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil).count > 0
                let signals = ScreenshotSignals(source: .photosMetadata, created: asset.creationDate, modified: asset.modificationDate ?? asset.creationDate ?? Date(), kept: kept, contentTerms: self.screenshotTerms[id])
                guard ScreenshotReview.assess(signals) != nil, try await self.fingerprint(asset).signature == expected else {
                    throw OpenFilesError.message("A screenshot changed or was saved to keep. Review screenshots again.")
                }
            }
            try Task.checkCancellation()
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
            guard assets.count == ids.count else { throw OpenFilesError.message("A selected screenshot is no longer available.") }
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            try await self.reload(); self.status = "Removed \(ids.count) reviewed screenshots through macOS. Changes may sync to iCloud and your other devices."
        }
    }
    private func fetch(_ id: String) -> PHAsset? { PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject }
    private func fingerprint(_ asset: PHAsset) async throws -> PhotoFingerprint {
        let date = asset.modificationDate
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { throw OpenFilesError.message("Originals unavailable") }
        var hashes: [PhotoResourceFingerprint] = []
        for resource in resources {
            try Task.checkCancellation()
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = allowDownloads
            let accumulator = PhotoResourceHash()
            let result: PhotoResourceFingerprint = try await withCheckedThrowingContinuation { continuation in
                PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { accumulator.append($0) }) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: accumulator.finish(kind: "\(resource.type.rawValue):\(resource.uniformTypeIdentifier)")) }
                }
            }
            hashes.append(result)
        }
        guard let current = fetch(asset.localIdentifier), current.modificationDate == date else { throw OpenFilesError.message("Photo changed during review") }
        let result = PhotoFingerprint(id: asset.localIdentifier, resources: hashes)
        guard result.signature != nil else { throw OpenFilesError.message("An original resource is empty or unavailable") }
        return result
    }
    func removeSelectedDuplicates() {
        let selection = selected, plan = groups
        guard archive == nil, duplicatesOnly else { return }
        run {
            try PhotoDuplicates.validate(selection, in: plan)
            let affected = plan.filter { !$0.items.allSatisfy { !selection.contains($0.id) } }
            // Recheck both removed photos and retained copies immediately before the library transaction.
            var fresh: [PhotoFingerprint] = []
            for item in affected.flatMap(\.items) {
                try Task.checkCancellation()
                guard let asset = self.fetch(item.id), (asset.modificationDate ?? .distantPast) == self.revisions[item.id] else {
                    throw OpenFilesError.message("The library changed since review. Check duplicates again before removing anything.")
                }
                fresh.append(try await self.fingerprint(asset))
            }
            try PhotoDuplicates.validateRecheck(selection, in: plan, current: fresh)
            try Task.checkCancellation()
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(selection), options: nil)
            guard assets.count == selection.count else { throw OpenFilesError.message("A selected photo is no longer available. Check duplicates again.") }
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            try await self.reload(); self.status = "Removed \(selection.count) reviewed duplicates through macOS Photos. Library deletion may sync to iCloud and your other devices."
        }
    }
    func createAlbum() {
        let ids = selected, name = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard archive == nil, !name.isEmpty, !ids.isEmpty else { return }
        run {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
            guard assets.count == ids.count else { throw OpenFilesError.message("Some selected photos are no longer available. Refresh and try again.") }
            try await PHPhotoLibrary.shared().performChanges {
                let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                album.addAssets(assets)
            }
            try await self.reload()
            self.albumName = ""; self.status = "Added \(ids.count) photos to \(name). Originals stay in the library."
        }
    }
    func favoriteSelected(_ value: Bool) {
        let ids = selected
        guard archive == nil, !ids.isEmpty else { return }
        run {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
            try await PHPhotoLibrary.shared().performChanges {
                assets.enumerateObjects { asset, _, _ in PHAssetChangeRequest(for: asset).isFavorite = value }
            }
            try await self.reload(); self.status = value ? "Selected photos marked as favorites." : "Favorites updated."
        }
    }
    func exportSelected() {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        let panel = NSOpenPanel(); panel.title = "Export copies of selected originals"; panel.prompt = "Export here"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        run {
            var completed = 0
            for item in chosen {
                try Task.checkCancellation()
                // A new subfolder per item keeps RAW/Live Photo companions and duplicate filenames together.
                let destination = folder.appendingPathComponent("\(URL(fileURLWithPath: item.name).deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8))", isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                do {
                    if let url = item.url { try FileManager.default.copyItem(at: url, to: destination.appendingPathComponent(item.name)) }
                    else if let asset = self.fetch(item.id) {
                        for (index, resource) in PHAssetResource.assetResources(for: asset).enumerated() {
                            let name = URL(fileURLWithPath: resource.originalFilename).lastPathComponent
                            let target = destination.appendingPathComponent("\(index + 1)-\(name)")
                            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = self.allowDownloads
                            try await PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: options)
                        }
                    } else { throw OpenFilesError.message("Selected photo is unavailable") }
                    completed += 1; self.status = "Exported \(completed) of \(chosen.count) photos"
                } catch {
                    // Remove only our newly created, incomplete export; library originals are never touched.
                    try? FileManager.default.removeItem(at: destination)
                    throw OpenFilesError.message("\(completed) photos exported. \(item.name): \(error.localizedDescription)")
                }
            }
            self.status = "Exported copies of \(completed) photos with all available resource companions."
        }
    }
    func analyzeContents() {
        let snapshot = items
        run {
            var count = 0, skipped = 0
            for (index, item) in snapshot.enumerated() {
                try Task.checkCancellation(); self.status = "Understanding photo contents · \(index + 1) of \(snapshot.count)"
                let revision = item.asset?.modificationDate ?? .distantPast
                if let url = item.url, let stamp = try? FileStamp.read(url), self.archiveAnalysisStamps[item.id] == stamp, self.analysis[item.id] != nil { continue }
                if item.asset != nil && self.analysisRevisions[item.id] == revision && self.analysis[item.id] != nil { continue }
                do {
                    let imageURL: URL, temporary: Bool
                    if let url = item.url { imageURL = url; temporary = false }
                    else {
                        guard let asset = item.asset, asset.mediaType == .image,
                              let image = await PhotoThumbnails.image(asset: asset, size: 1024, network: self.allowDownloads), let data = image.tiffRepresentation else { skipped += 1; continue }
                        imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesPhoto-\(UUID()).tiff")
                        try data.write(to: imageURL, options: [.atomic]); temporary = true
                    }
                    defer { if temporary { try? FileManager.default.removeItem(at: imageURL) } }
                    let url = imageURL
                    let terms = try await Task.detached(priority: .utility) { try PhotoMediaAnalysis.terms(at: url) }.value
                    try Task.checkCancellation()
                    self.analysis[item.id] = terms
                    if let url = item.url { self.archiveAnalysisStamps[item.id] = try FileStamp.read(url) }
                    else { self.analysisRevisions[item.id] = revision }
                    if let i = self.items.firstIndex(where: { $0.id == item.id }) { self.items[i].terms += terms }
                    count += 1
                } catch is CancellationError { throw CancellationError() }
                catch { skipped += 1 }
            }
            self.status = "Photo content search ready · \(count) analyzed · \(skipped) unavailable or unsupported. Analysis stays on this Mac."
        }
    }
    func cancel() { job?.cancel(); status = "Stopping after the current photo…" }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        job = Task {
            defer { busy = false; job = nil }
            do { try await work() }
            catch is CancellationError { status = "Stopped. Completed review results are kept; originals are unchanged." }
            catch { self.error = error.localizedDescription }
        }
    }
}

enum PhotoThumbnails {
    static func image(asset: PHAsset, size: Int, network: Bool = false) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let options = PHImageRequestOptions(); options.isSynchronous = true; options.isNetworkAccessAllowed = network
            options.deliveryMode = .highQualityFormat; options.resizeMode = .fast
            var result: NSImage?
            PHImageManager.default().requestImage(for: asset, targetSize: NSSize(width: size, height: size), contentMode: .aspectFit, options: options) { image, _ in result = image }
            return result
        }.value
    }
    static func image(url: URL, size: Int) async -> NSImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: .zero)
        }.value
    }
}
