import SwiftUI
import AppKit
import OpenFilesCore

@MainActor
final class CleanupModel: ObservableObject {
    @Published var scope: URL?
    @Published private(set) var review: CleanupReview?
    @Published var selected = Set<UUID>()
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var result: CleanupResult?
    private let service: CleanupService
    private let library: FileLibrary
    private var task: Task<Void, Never>?
    init(library: FileLibrary, directory: URL) {
        self.library = library; service = CleanupService(directory: directory)
    }
    var selectedFiles: [CleanupFile] { review?.files.filter { selected.contains($0.id) } ?? [] }
    var selectedBytes: Int64 { selectedFiles.reduce(0) { $0 + $1.bytes } }
    var canTrash: Bool {
        guard !busy, !selected.isEmpty, let review else { return false }
        return review.duplicates.allSatisfy { !$0.files.allSatisfy { selected.contains($0.id) } }
    }
    func chooseFolder() {
        let picker = NSOpenPanel()
        picker.title = "Choose a folder to review for cleanup"
        picker.message = "Reviews indexed files inside this folder. No files are changed during analysis."
        picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK else { return }
        scope = picker.url?.resolvingSymlinksInPath().standardizedFileURL
        review = nil; selected = []; result = nil
    }
    func analyze(excluding: [URL]) {
        guard let scope, !busy else { return }
        busy = true; error = nil; review = nil; selected = []; result = nil
        task = Task {
            defer { busy = false }
            do {
                let current = await library.current()
                review = try await service.preview(files: current.files, scope: scope, excluding: excluding)
            } catch is CancellationError { error = "Review cancelled. No files were changed." }
            catch { self.error = error.localizedDescription }
        }
    }
    func cancel() { task?.cancel() }
    func trashSelected(excluding: [URL]) {
        guard canTrash, let review else { return }
        let selection = selected
        busy = true; error = nil
        task = Task {
            defer { busy = false }
            do {
                result = try await service.apply(reviewID: review.id, selected: selection, excluding: excluding)
                self.review = nil; selected = []
                if let result, !result.receipts.isEmpty {
                    _ = try? await library.synchronizeChanges(result.receipts.map(\.original))
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private typealias CleanupViewState<Value> = SwiftUI.State<Value>

struct CleanupView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: CleanupModel
    @CleanupViewState private var confirming = false
    private var protected: [URL] {
        app.protection.state.locations.map(\.url) + app.packs.packs.flatMap(\.items).flatMap(\.attachments).map(\.url) + app.indexSettings.excludedFolders
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Make room, with a second look.").font(.largeTitle.weight(.semibold))
                    Text("Find identical files and review things you may no longer need. You choose what goes to Trash.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(model.scope?.path ?? "Choose a folder to review", systemImage: "folder")
                                .lineLimit(1).truncationMode(.middle).help(model.scope?.path ?? "")
                            Spacer()
                            Button(model.scope == nil ? "Choose folder and review…" : "Change folder…") {
                                let previous = model.scope
                                model.chooseFolder()
                                if model.scope != nil && (model.scope != previous || model.review == nil) { model.analyze(excluding: protected) }
                            }.disabled(model.busy)
                            if model.scope != nil {
                                Button("Check again") { model.analyze(excluding: protected) }
                                    .buttonStyle(.borderedProminent).disabled(model.busy)
                            }
                        }
                        Text("Uses indexed files only. Protected locations, document-pack attachments, projects, links, sensitive-classified files and iCloud items are excluded. Other cloud folders may sync Trash changes to other devices; choose a local folder.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if model.busy {
                            HStack { ProgressView().controlSize(.small); Text("Checking files…"); Spacer(); Button("Cancel") { model.cancel() } }
                        }
                    }.padding(10)
                }
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
                if let result = model.result {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("\(result.receipts.count) files moved to Trash", systemImage: "trash")
                                .font(.headline)
                            Text("Restore them using Finder’s Trash → Put Back. Trash may be emptied by you or macOS, so it is not a backup.")
                                .foregroundStyle(.secondary)
                            Button("Open Trash") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")) }
                            ForEach(result.receipts) { receipt in
                                Text(receipt.original.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            ForEach(result.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let review = model.review {
                    HStack {
                        Text("\(review.duplicates.count) duplicate groups · \(review.suggestions.count) suggestions").font(.headline)
                        Spacer()
                        Text("\(review.skipped) skipped").font(.caption).foregroundStyle(.secondary)
                    }
                    if review.limited {
                        Label("Partial review: limited to 5,000 eligible files, 256 MB per file and 2 GB of hashing, and 100,000 similarity comparisons. Review a smaller folder for more coverage.", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Nothing is selected automatically. Similarity and file age cannot tell whether a file matters to you.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(review.duplicates) { group in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Identical contents · \(group.files.count) copies").font(.headline)
                                    Spacer()
                                    Text("Up to \(bytes(group.possibleSavings))").foregroundStyle(.secondary)
                                }
                                Text("Keep at least one copy. Different locations may be used by apps, projects or shared folders.")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(group.files) { file in fileRow(file) }
                                if group.files.allSatisfy({ model.selected.contains($0.id) }) {
                                    Label("Deselect a copy to keep it.", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                                }
                            }.padding(10)
                        }
                    }
                    if !review.suggestions.isEmpty {
                        Text("Worth a look").font(.title2.weight(.semibold))
                        Text(review.usesEmbeddings ? "Local AI compares document contents. A newer, similar document may still contain different information." : "These suggestions use file type, folder and modification time. No AI model determined that they are unwanted.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(review.suggestions) { file in GroupBox { fileRow(file).padding(10) } }
                    }
                    if review.files.isEmpty {
                        ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle", description: Text("No eligible matches in the indexed files here. Check indexing coverage or choose another folder."))
                    } else {
                        HStack {
                            Text("\(model.selected.count) selected · \(bytes(model.selectedBytes))").foregroundStyle(.secondary)
                            Spacer()
                            Button("Deselect all") { model.selected = [] }.disabled(model.busy)
                            Button("Review Trash selection…", role: .destructive) { confirming = true }.disabled(!model.canTrash)
                        }
                    }
                }
            }.padding(30).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $confirming) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Move \(model.selected.count) files to Trash?").font(.title2.weight(.semibold))
                Text("Review every path below. Exact duplicates can have different metadata or app references. Suggestions may still be valuable. Files are checked again before moving.")
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.selectedFiles) { file in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.url.lastPathComponent).fontWeight(.medium)
                                Text(file.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                Text(file.kind.rawValue).font(.caption)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 300)
                HStack {
                    Spacer()
                    Button("Cancel") { confirming = false }.keyboardShortcut(.cancelAction)
                    Button("Move to Trash", role: .destructive) { confirming = false; model.trashSelected(excluding: protected) }.disabled(!model.canTrash)
                }
            }.padding(26).frame(width: 580)
        }
    }
    private func fileRow(_ file: CleanupFile) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Select \(file.url.lastPathComponent) for Trash", isOn: Binding(get: { model.selected.contains(file.id) }, set: {
                if $0 { model.selected.insert(file.id) } else { model.selected.remove(file.id) }
            })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
            VStack(alignment: .leading, spacing: 5) {
                Text(file.url.lastPathComponent).font(.headline)
                Text(file.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                Text("\(bytes(file.bytes)) · modified \(file.modified.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                Text(file.evidence).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let related = file.relatedURL {
                    Button("Compare with \(related.lastPathComponent)") { NSWorkspace.shared.activateFileViewerSelecting([file.url, related]) }.font(.caption)
                }
            }
            Spacer(minLength: 4)
            Button("Preview") { app.previewItem = BrowserItem(url: file.url, isFolder: false, isPackage: false, size: file.bytes, modified: file.modified) }
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}
