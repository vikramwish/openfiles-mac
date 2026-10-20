import SwiftUI
import Photos
import OpenFilesCore

private typealias PhotoViewState<Value> = SwiftUI.State<Value>

@MainActor
struct PhotoLibraryView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: PhotoLibraryModel
    @PhotoViewState private var confirmingRemoval = false
    @PhotoViewState private var preview: LibraryPhoto?
    private struct DuplicateSection: Identifiable {
        let group: PhotoDuplicateGroup
        let photos: [LibraryPhoto]
        var id: String { group.id }
    }
    private var duplicateSections: [DuplicateSection] {
        let visible = Dictionary(model.visibleItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return model.groups.compactMap { group in
            let photos = group.items.compactMap { visible[$0.id] }
            return photos.isEmpty ? nil : DuplicateSection(group: group, photos: photos)
        }
    }
    private struct SimilarSection: Identifiable {
        let group: PhotoSimilarityGroup
        let photos: [LibraryPhoto]
        var id: String { group.id }
    }
    private var similarSections: [SimilarSection] {
        let visible = Dictionary(model.visibleItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let all = Dictionary(model.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return model.similarGroups.compactMap { group in
            guard group.photoIDs.contains(where: { visible[$0] != nil }) else { return nil }
            // Keep the reference visible even when a search only matches one of its neighbors.
            let photos = group.photoIDs.compactMap { visible[$0] ?? ($0 == group.referenceID ? all[$0] : nil) }
            return photos.isEmpty ? nil : SimilarSection(group: group, photos: photos)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.archive?.lastPathComponent ?? "Your photos").font(.title2.weight(.semibold))
                    Text(model.archive == nil ? "Find, collect, and clean up photos here. Originals stay in their library." : "Local originals · read-only inspection")
                        .foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                Button(model.connected && model.archive == nil ? "Refresh" : "Connect Photos") {
                    if model.connected && model.archive == nil { model.refresh() } else { model.connect() }
                }.disabled(model.busy)
                Button("Choose library…") { model.chooseLibrary() }.disabled(model.busy)
            }
            if !model.connected {
                ContentUnavailableView {
                    Label("Your photo tools, in OpenFiles", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Connect your System Photo Library to browse photos, find exact and similar photos, search image contents, create albums, mark favorites, and export originals. macOS will ask for permission. Photos doesn’t need to be open.")
                } actions: {
                    Button("Connect my photos") { model.connect() }.buttonStyle(.borderedProminent).disabled(model.busy)
                }
            } else {
                HStack(spacing: 10) { reviewControls; Spacer() }
                if model.archive == nil { downloadControl }
                HStack {
                    Picker("Show photos", selection: $model.reviewMode) {
                        Text("All · \(model.items.count)").tag(PhotoReviewMode.all)
                        Text("Exact · \(model.groups.count)").tag(PhotoReviewMode.duplicates)
                        Text("Similar · \(model.similarGroups.count)").tag(PhotoReviewMode.similar)
                        Text("Screenshots · \(model.screenshotSuggestions.count)").tag(PhotoReviewMode.screenshots)
                    }.pickerStyle(.segmented).frame(maxWidth: 400)
                    Spacer()
                    if model.duplicatesOnly && !model.groups.isEmpty {
                        Button("Select extra copies") { model.selectExtraCopies() }.disabled(model.busy)
                    } else if !model.visibleItems.isEmpty {
                        Button("Select shown") { model.selected = Set(model.visibleItems.map(\.id)) }.disabled(model.busy)
                    }
                    Text("\(model.selected.count) selected").font(.callout).foregroundStyle(.secondary)
                    if !model.selected.isEmpty { Button("Deselect") { model.selected = [] } }
                }
                if !model.selected.isEmpty {
                    HStack(spacing: 10) { selectionControls }
                }
                if model.screenshotsOnly {
                    Text("Older screenshot suggestions, ranked for review. Favorites, albums, recent changes, and recognized important records are left out. Photos doesn’t provide last-viewed history.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if model.similarOnly {
                    HStack {
                        Text("Similar appearance isn’t proof of a duplicate. Compare each photo before deciding what to keep.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Picker("Match range", selection: $model.similarityScope) {
                            ForEach(PhotoSimilarityScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.frame(maxWidth: 210).disabled(model.busy)
                    }
                }
                if model.duplicatesOnly {
                    Text(model.archive == nil ? "Exact matches include original bytes, edited resources, and Live Photo companions. Choose what to remove; keep at least one in each group. Photos may share identical images with different dates, albums, or favorites—review before removing." : "Matching original files are shown together. These are file matches, not confirmed duplicate Photos assets. Bundles are never modified directly; connect the System Photo Library for library-safe cleanup.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                    if model.duplicatesOnly {
                        if model.groups.isEmpty {
                            ContentUnavailableView("No duplicate groups to review", systemImage: "checkmark.circle", description: Text("Run Find duplicates to check the originals you can access. Unavailable originals are reported, not assumed to be unique."))
                        }
                        ForEach(duplicateSections) { section in
                            let group = section.group
                            let photos = section.photos
                            if !photos.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("\(group.items.count) matches · up to \(ByteCountFormatter.string(fromByteCount: group.possibleSavings, countStyle: .file)) in original resources")
                                        .font(.headline)
                                    photoGrid(photos)
                                }.padding(.vertical, 10)
                            }
                        }
                    } else if model.similarOnly {
                        if similarSections.isEmpty {
                            ContentUnavailableView("No similar groups to review", systemImage: "photo.on.rectangle.angled", description: Text("Use Find similar to compare the images you can access. Broader matches can include more variations."))
                        }
                        ForEach(similarSections) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("\(section.group.photoIDs.count) similar-looking photos").font(.headline)
                                Text("Matches are compared with the first photo in this group. No photos are selected for removal.")
                                    .font(.caption).foregroundStyle(.secondary)
                                photoGrid(section.photos)
                            }.padding(.vertical, 10)
                        }
                    } else if model.screenshotsOnly {
                        if model.visibleItems.isEmpty {
                            ContentUnavailableView("No older screenshots to review", systemImage: "rectangle.dashed", description: Text("Use Review screenshots to find older captures that may have outlived their purpose. Recent or saved captures stay out."))
                        }
                        photoGrid(model.visibleItems)
                    } else {
                        if model.visibleItems.isEmpty {
                            ContentUnavailableView("No matching photos", systemImage: "photo", description: Text("Try a filename or date. Use Understand contents to search subjects and text inside images."))
                        }
                        photoGrid(model.visibleItems)
                    }
                    }
                }.frame(minHeight: 100, maxHeight: .infinity)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if model.busy { ProgressView().controlSize(.small); Button("Stop") { model.cancel() } }
                Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(20)
        .onAppear { model.query = app.query }
        .onChange(of: app.query) { model.query = app.query }
        .onChange(of: model.similarityScope) { if model.similarOnly && !model.busy { model.findSimilar() } }
        .confirmationDialog(model.screenshotsOnly ? "Remove \(model.selected.count) reviewed screenshots?" : "Remove \(model.selected.count) reviewed duplicate photos?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(model.screenshotsOnly ? "Remove reviewed screenshots" : "Remove selected duplicates", role: .destructive) {
                if model.screenshotsOnly { model.removeReviewedScreenshots() } else { model.removeSelectedDuplicates() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.screenshotsOnly ? "These screenshots are suggestions, not proven unused files. Remove only the captures you no longer need. macOS will remove them from the library; iCloud Photos may sync deletion to your other devices. Originals and keep signals are checked again before removal." : "macOS will remove these assets from your photo library and its albums. If you use iCloud Photos, deletion also syncs to other devices. One fully checked copy per group must remain. macOS may ask you to confirm the change.")
        }
        .sheet(item: $preview) { item in
            VStack(spacing: 12) {
                HStack { Text(item.name).font(.headline); Spacer(); Button("Done") { preview = nil }.keyboardShortcut(.cancelAction) }
                PhotoThumbnail(item: item, size: 900).frame(maxWidth: .infinity, maxHeight: .infinity)
                if let date = item.date { Text(date, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary) }
            }.padding(20).frame(minWidth: 620, minHeight: 480)
        }
    }
    private var reviewControls: some View {
        Group {
            Button { model.findDuplicates() } label: { Label("Find duplicates", systemImage: "square.on.square") }
            Button { model.reviewScreenshots() } label: { Label("Review screenshots", systemImage: "rectangle.dashed") }
            Button { model.findSimilar() } label: { Label("Find similar", systemImage: "photo.on.rectangle.angled") }
            Button { model.analyzeContents() } label: { Label("Understand contents", systemImage: "sparkles") }
        }.disabled(model.busy)
    }
    private var downloadControl: some View {
        Toggle("Download cloud originals when needed", isOn: $model.allowDownloads)
            .toggleStyle(.checkbox).font(.caption).disabled(model.busy || model.archive != nil)
            .help("May use network data and temporary disk space. Off means local resources only.")
    }
    private var selectionControls: some View {
        Group {
            Button("Export originals…") { model.exportSelected() }.disabled(model.busy)
            if model.archive == nil {
                Menu("Favorites") {
                    Button("Mark as favorites") { model.favoriteSelected(true) }
                    Button("Remove favorite mark") { model.favoriteSelected(false) }
                }.disabled(model.busy)
                TextField("New album name", text: $model.albumName).textFieldStyle(.roundedBorder).frame(maxWidth: 190)
                Button("Create album") { model.createAlbum() }.disabled(model.busy || model.albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.screenshotsOnly {
                    Button("Remove reviewed screenshots…", role: .destructive) { confirmingRemoval = true }
                        .disabled(!model.canRemoveScreenshots)
                }
                if model.duplicatesOnly {
                    Button("Remove duplicates…", role: .destructive) { confirmingRemoval = true }
                        .disabled(!model.canRemoveDuplicates)
                }
            }
        }
    }
    private func photoGrid(_ photos: [LibraryPhoto]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: model.screenshotsOnly ? 220 : 140), spacing: 12)], spacing: 12) {
            ForEach(photos) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Button { preview = item } label: {
                        PhotoThumbnail(item: item, size: 220).frame(height: 120).frame(maxWidth: .infinity)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8)).clipped()
                    }.buttonStyle(.plain).accessibilityLabel("Preview \(item.name)")
                    Toggle(isOn: Binding(get: { model.selected.contains(item.id) }, set: { value in
                        if value { model.selected.insert(item.id) } else { model.selected.remove(item.id) }
                    })) { Text(item.name).lineLimit(1).help(item.name) }
                        .toggleStyle(.checkbox).disabled(model.busy)
                    HStack {
                        if let date = item.date { Text(date, format: .dateTime.year().month(.abbreviated).day()) }
                        if item.favorite { Image(systemName: "heart.fill").accessibilityLabel("Favorite") }
                    }.font(.caption2).foregroundStyle(.secondary)
                    if model.screenshotsOnly, let suggestion = model.screenshotSuggestions[item.id] {
                        Text(suggestion.evidence).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if model.archive == nil && !model.screenshotRemovalAvailable(item.id) {
                            Text("Original unavailable for verified removal.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !item.albums.isEmpty { Text(item.albums.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(item.albums.joined(separator: ", ")) }
                }.padding(8).background(model.selected.contains(item.id) ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct PhotoThumbnail: View {
    let item: LibraryPhoto
    let size: Int
    @PhotoViewState private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: item.asset?.mediaType == .video ? "video" : "photo").font(.largeTitle).foregroundStyle(.secondary) }
        }.task(id: item.id + "-\(size)") {
            let result: NSImage?
            if let url = item.url { result = await PhotoThumbnails.image(url: url, size: size) }
            else if let asset = item.asset { result = await PhotoThumbnails.image(asset: asset, size: size) }
            else { result = nil }
            guard !Task.isCancelled else { return }; image = result
        }
    }
}
