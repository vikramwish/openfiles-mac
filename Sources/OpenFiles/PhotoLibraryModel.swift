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

@MainActor
final class PhotoLibraryModel: ObservableObject {
    @Published private(set) var items: [LibraryPhoto] = []
    @Published private(set) var groups: [PhotoDuplicateGroup] = []
    @Published private(set) var connected = false
    @Published private(set) var archive: URL?
    @Published private(set) var busy = false
    @Published private(set) var status = "Connect your photos to browse, search, organize, and find duplicates here."
    @Published var error: String?
    @Published var selected = Set<String>()
    @Published var query = ""
    @Published var duplicatesOnly = false
    @Published var allowDownloads = false
    @Published var albumName = ""
    private var job: Task<Void, Never>?
    private var reviewed: [String: PhotoFingerprint] = [:]
    private var revisions: [String: Date] = [:]
    private var analysis: [String: [String]] = [:]
    var selectedItems: [LibraryPhoto] { items.filter { selected.contains($0.id) } }
    var visibleItems: [LibraryPhoto] {
        let duplicateIDs = Set(groups.flatMap { $0.items.map(\.id) })
        let words = FileSearchQuery.words(query)
        return items.filter { item in
            (!duplicatesOnly || duplicateIDs.contains(item.id)) && words.allSatisfy { word in
                FileSearchQuery.words(([item.name, item.date?.formatted(date: .long, time: .omitted) ?? ""] + item.terms).joined(separator: " ")).contains { $0.hasPrefix(word) }
            }
        }
    }
    var canRemoveDuplicates: Bool {
        guard !busy, archive == nil, connected else { return false }
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
            self.reload()
        }
    }
    func refresh() {
        guard archive == nil else { if let archive { inspect(archive) }; return }
        run {
            let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard access == .authorized || access == .limited else { throw OpenFilesError.message("Photo access changed. Connect Photos again to refresh.") }
            self.reload()
        }
    }
    private func reload() {
        let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetched = PHAsset.fetchAssets(with: options)
        var photos: [LibraryPhoto] = []
        fetched.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else { return }
            let resources = PHAssetResource.assetResources(for: asset)
            var terms = self.analysis[asset.localIdentifier] ?? []
            if let location = asset.location { terms += PhotoMediaAnalysis.placeTerms(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude) }
            if asset.isFavorite { terms += ["favorite", "favourite"] }
            photos.append(.init(id: asset.localIdentifier, name: resources.first?.originalFilename ?? "Photo", date: asset.creationDate, favorite: asset.isFavorite, url: nil, asset: asset, terms: terms))
        }
        items = photos; groups = []; reviewed = [:]; revisions = [:]; selected = []
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
            let result = try await Task.detached(priority: .utility) {
                try await PhotoArchive.review(url) { count in await MainActor.run { self.status = "Checking local originals · \(count) read" } }
            }.value
            self.archive = result.library; self.connected = true; self.groups = result.groups
            self.reviewed = Dictionary(result.groups.flatMap(\.items).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.items = result.photos.map { .init(id: $0.id, name: $0.url.lastPathComponent, date: $0.stamp.modified, favorite: false, url: $0.url, asset: nil, terms: self.analysis[$0.id] ?? []) }
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
            self.reviewed = Dictionary(prints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.revisions = dates; self.selected = []; self.duplicatesOnly = true
            self.status = "\(self.groups.count) exact duplicate groups · \(prints.count) fully checked · \(skipped) unavailable or changed. Edited resources and Live Photo components must also match."
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
        return PhotoFingerprint(id: asset.localIdentifier, resources: hashes)
    }
    func removeSelectedDuplicates() {
        let selection = selected, plan = groups
        guard archive == nil else { return }
        run {
            try PhotoDuplicates.validate(selection, in: plan)
            let affected = plan.filter { !$0.items.allSatisfy { !selection.contains($0.id) } }
            // Recheck both removed photos and retained copies immediately before the library transaction.
            for item in affected.flatMap(\.items) {
                try Task.checkCancellation()
                guard let asset = self.fetch(item.id), asset.modificationDate ?? .distantPast == self.revisions[item.id],
                      let expected = self.reviewed[item.id]?.signature,
                      try await self.fingerprint(asset).signature == expected else {
                    throw OpenFilesError.message("The library changed since review. Check duplicates again before removing anything.")
                }
            }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(selection), options: nil)
            guard assets.count == selection.count else { throw OpenFilesError.message("A selected photo is no longer available. Check duplicates again.") }
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            self.reload(); self.status = "Removed \(selection.count) reviewed duplicates through macOS Photos. Library deletion may sync to iCloud and your other devices."
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
            self.reload(); self.status = value ? "Selected photos marked as favorites." : "Favorites updated."
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
                if self.analysis[item.id] != nil { continue }
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
                    self.analysis[item.id] = terms
                    if let i = self.items.firstIndex(where: { $0.id == item.id }) { self.items[i].terms += terms }
                    count += 1
                } catch { skipped += 1 }
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
