import SwiftUI
import AppKit
import OpenFilesCore

@MainActor
final class DeveloperCleanupModel: ObservableObject {
    var automaticScopes: [URL]?
    @Published private(set) var scope: URL?
    @Published private(set) var review: DeveloperCleanupReview?
    @Published var selected = Set<UUID>()
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var result: CleanupResult?
    @Published var workloadsStopped = false
    private let library: FileLibrary
    private let service: DeveloperCleanupService
    private var task: Task<Void, Never>?
    init(library: FileLibrary, directory: URL) { self.library = library; service = DeveloperCleanupService(directory: directory) }
    var selectedItems: [DeveloperCleanupItem] { review?.items.filter { selected.contains($0.id) } ?? [] }
    var canTrash: Bool { !busy && workloadsStopped && !selectedItems.isEmpty && selectedItems.allSatisfy(\.canTrash) }
    func chooseFolder(excluding: [URL]) {
        let picker = NSOpenPanel()
        picker.title = "Review developer disk usage"
        picker.message = "Choose a project folder, developer cache folder, or your home folder. This scan includes generated folders skipped by file search."
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        scope = url.resolvingSymlinksInPath().standardizedFileURL
        analyze(excluding: excluding)
    }
    func analyze(excluding: [URL]) {
        guard !busy else { return }
        let chosen = scope
        busy = true; review = nil; result = nil; selected = []; error = nil; workloadsStopped = false
        task = Task {
            defer { busy = false }
            do {
                let roots: [URL]
                if let chosen { roots = [chosen] }
                else {
                    let indexed = await library.indexScopes()
                    roots = MacScanScopes.reduce(automaticScopes ?? (MacScanScopes.defaults() + indexed))
                }
                review = try await service.preview(scope: chosen ?? FileManager.default.homeDirectoryForCurrentUser, excluding: excluding, scopes: roots)
            }
            catch is CancellationError { error = "Scan cancelled. No files were changed." }
            catch { self.error = error.localizedDescription }
        }
    }
    func useEntireMac(excluding: [URL]) { scope = nil; analyze(excluding: excluding) }
    func prepareAutomatically(excluding: [URL]) {
        if scope == nil && review == nil && result == nil && !busy { analyze(excluding: excluding) }
    }
    func refreshAutomatically(excluding: [URL]) {
        if scope == nil && selected.isEmpty && result == nil && !busy { analyze(excluding: excluding) }
    }
    func cancel() { task?.cancel() }
    func moveToTrash(excluding: [URL]) {
        guard canTrash, let review else { return }
        let selection = selected
        busy = true; error = nil
        task = Task {
            defer { busy = false }
            do {
                result = try await service.apply(reviewID: review.id, selected: selection, workloadsStopped: workloadsStopped, excluding: excluding)
                self.review = nil; selected = []; workloadsStopped = false
            } catch { self.error = error.localizedDescription }
        }
    }
}

private typealias DeveloperViewState<Value> = SwiftUI.State<Value>

struct DeveloperCleanupView: View {
    @ObservedObject var model: DeveloperCleanupModel
    let protected: [URL]
    @DeveloperViewState private var confirming = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Room for your next build.").font(.largeTitle.weight(.semibold))
                    Text("See the space used by dependencies, environments, build output and developer caches.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(model.scope?.path ?? "This Mac · developer folders and caches", systemImage: "terminal")
                                .lineLimit(1).truncationMode(.middle).help(model.scope?.path ?? "")
                            Spacer()
                            Menu("Scope") {
                                Button("This Mac") { model.useEntireMac(excluding: protected) }
                                Button("Choose a specific folder…") { model.chooseFolder(excluding: protected) }
                            }.disabled(model.busy)
                            Button("Check again") { model.analyze(excluding: protected) }.disabled(model.busy)
                        }
                        Text("Scans folders directly, including generated files excluded from search. No indexing pass or AI model is needed. No package commands run.")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.busy {
                            HStack { ProgressView().controlSize(.small); Text("Measuring and checking folders…"); Spacer(); Button("Cancel") { model.cancel() } }
                        }
                    }.padding(10)
                }
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
                if let result = model.result {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("\(result.receipts.count) items moved to Trash", systemImage: "trash").font(.headline)
                            Text("Use Finder’s Trash → Put Back to restore them. Moving items to Trash does not immediately free disk space. Emptying Trash permanently removes its contents; this app does not do that.")
                                .foregroundStyle(.secondary)
                            Button("Open Trash") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")) }
                            ForEach(result.receipts) { Text($0.original.path).font(.caption).textSelection(.enabled) }
                            ForEach(result.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let review = model.review {
                    HStack {
                        Text("\(review.items.count) items · \(bytes(review.selectableBytes)) eligible for review").font(.headline)
                        Spacer()
                        Text("\(review.visited) paths checked · \(review.skipped) skipped").font(.caption).foregroundStyle(.secondary)
                    }
                    if review.limited {
                        Label("Partial scan. Some items could not be fully measured or a scan limit was reached. Incomplete items cannot be removed here.", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Sizes are allocated disk estimates; APFS clones, compression and hard links can change actual savings. A dependency folder may contain local edits. Keep anything you cannot recreate.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(review.items) { item in itemRow(item) }
                    if review.items.isEmpty {
                        ContentUnavailableView("No developer artifacts found", systemImage: "terminal", description: Text("Choose a project containing dependencies, or your home folder to include known developer caches. System and protected locations are skipped."))
                    } else {
                        Toggle("I have stopped affected servers, Python sessions and builds", isOn: $model.workloadsStopped).disabled(model.busy)
                        HStack {
                            Text("\(model.selected.count) selected · \(bytes(model.selectedItems.reduce(0) { $0 + $1.bytes }))").foregroundStyle(.secondary)
                            Spacer()
                            Button("Deselect all") { model.selected = [] }.disabled(model.busy)
                            Button("Review Trash selection…", role: .destructive) { confirming = true }.disabled(!model.canTrash)
                        }
                    }
                }
                Text("Protected locations, document-pack attachments and app data are excluded. Internal dependency symlinks are measured as links; their targets are never scanned or removed. No VM disk, container volume, shared Python runtime or source repository can be selected. Known iCloud items are skipped; other cloud folders may sync removals, so choose local folders.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(30).frame(maxWidth: 1050).frame(maxWidth: .infinity)
        }
        .task { model.prepareAutomatically(excluding: protected) }
        .sheet(isPresented: $confirming) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Move \(model.selected.count) developer items to Trash?").font(.title2.weight(.semibold))
                Text("These are entire folders, including installed packages, local edits and cached downloads. Review the rebuild guidance for each item. Nothing will reinstall automatically.")
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.selectedItems) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.url.path).fontWeight(.medium).textSelection(.enabled)
                                Text(item.recovery).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 320)
                HStack {
                    Spacer()
                    Button("Cancel") { confirming = false }.keyboardShortcut(.cancelAction)
                    Button("Move to Trash", role: .destructive) { confirming = false; model.moveToTrash(excluding: protected) }.disabled(!model.canTrash)
                }
            }.padding(26).frame(width: 620)
        }
    }
    private func itemRow(_ item: DeveloperCleanupItem) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Toggle("Select \(item.url.path) for Trash", isOn: Binding(get: { model.selected.contains(item.id) }, set: {
                    if $0 { model.selected.insert(item.id) } else { model.selected.remove(item.id) }
                })).labelsHidden().toggleStyle(.checkbox).disabled(!item.canTrash || model.busy)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.url.lastPathComponent).font(.headline)
                        Spacer()
                        Text(item.complete ? bytes(item.bytes) : "Size unavailable").foregroundStyle(.secondary)
                    }
                    Label(item.category + (item.canTrash ? " · review before removal" : " · inspection only"), systemImage: item.canTrash ? "arrow.trianglehead.clockwise" : "lock.shield")
                        .font(.caption.weight(.medium))
                    Text(item.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(item.evidence).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(item.recovery).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }.font(.caption)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}
