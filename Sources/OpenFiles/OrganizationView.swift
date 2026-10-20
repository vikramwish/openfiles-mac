import SwiftUI
import OpenFilesCore

@MainActor
final class OrganizationSession: ObservableObject {
    @Published var preview: OrganizationPreview?
    @Published var selection = Set<UUID>()
    @Published var analyzing = false
    @Published var applying = false
    var analysisID = UUID()
    var analysis: Task<Void, Never>?
}

@MainActor
struct OrganizationView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: OrganizationSession
    var automaticallyAnalyze = false
    private var preview: OrganizationPreview? { get { session.preview } nonmutating set { session.preview = newValue } }
    private var selection: Set<UUID> { get { session.selection } nonmutating set { session.selection = newValue } }
    private var analyzing: Bool { get { session.analyzing } nonmutating set { session.analyzing = newValue } }
    private var applying: Bool { get { session.applying } nonmutating set { session.applying = newValue } }
    private var analysisID: UUID { get { session.analysisID } nonmutating set { session.analysisID = newValue } }
    private var analysis: Task<Void, Never>? { get { session.analysis } nonmutating set { session.analysis = newValue } }
    private var topics: [String] { Array(Set(preview?.suggestions.map(\.topic) ?? [])).sorted() }

    var body: some View {
        GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "folder.badge.gearshape").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Organize your files").font(.title2.weight(.semibold))
                    Text("Folder suggestions use document content, image subjects, filenames, and existing locations. Review the destination and preview each file before moving it.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !automaticallyAnalyze {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Across this Mac", systemImage: "desktopcomputer").font(.headline)
                        Spacer()
                        Button("Manage folders…") { model.showingIndexing = true }
                    }
                    Text("Apps, project contents, and potentially private files stay where they are.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text("\(model.state.files.count) files ready to organize").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh files") { model.startIndexing() }.disabled(model.indexing)
                        Button("Add Location…") { preview = nil; model.chooseOrganizationFolder() }
                    }
                    DisclosureGroup("Included folders · \(model.state.roots.count)") {
                    ForEach(model.state.roots, id: \.self) { root in
                        HStack {
                            Label(root.path, systemImage: "folder").lineLimit(1).truncationMode(.middle).help(root.path)
                            Spacer()
                            Button("Remove") { preview = nil; model.removeFolder(root) }.buttonStyle(.borderless)
                        }.font(.callout)
                    }
                    }
                }.padding(8)
            }.disabled(analyzing || applying)
            } else {
                Label("\(model.state.files.count) files available · \(model.state.roots.count) added folders", systemImage: "desktopcomputer")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if analyzing {
                    ProgressView().controlSize(.small)
                    Text("Finding related files…").font(.callout)
                    Button("Cancel") { analysis?.cancel(); analyzing = false }
                } else {
                    Button(preview == nil ? "Find suggestions" : "Check again") { analyze() }.disabled(applying)
                }
                Spacer()
                if let preview, !preview.suggestions.isEmpty {
                    Button(selection.count == preview.suggestions.count ? "Deselect All" : "Select All") {
                        selection = selection.count == preview.suggestions.count ? [] : Set(preview.suggestions.map(\.id))
                    }.disabled(applying)
                    Button("Move \(selection.count) Selected Files") { apply(preview) }
                        .buttonStyle(.borderedProminent).disabled(selection.isEmpty || applying || analyzing)
                }
            }
            if applying { ProgressView("Moving selected files and updating the index…").controlSize(.small) }
            if let preview {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(preview.suggestions.count) suggestions from \(preview.indexedFiles) files").font(.headline)
                    Text("Destination: \(preview.destination.path)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if preview.deferred > 0 {
                        Text("\(preview.deferred) more matches are waiting. Review up to 200 suggestions per pass, then analyze again.").font(.callout).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Why some files stay in place") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(preview.skipped.keys.sorted(), id: \.self) { reason in
                                Text("\(preview.skipped[reason] ?? 0) · \(reason)")
                            }
                            Text("Only files with readable content are considered. Files with unclear matches stay in their current folders.")
                        }.font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                    }
                }
                if !preview.modelAvailable {
                    ContentUnavailableView("File understanding is unavailable", systemImage: "exclamationmark.magnifyingglass", description: Text("File understanding isn’t available right now. Check file activity and try again."))
                } else if preview.suggestions.isEmpty {
                    ContentUnavailableView(preview.indexedFiles == 0 ? "Add a folder to get started" : "No clear matches yet", systemImage: "folder.badge.plus", description: Text(preview.indexedFiles == 0 ? "Use Add folder above to choose the files you want OpenFiles to organize." : "Files with unclear matches stay in their current folders. Add more folders or refresh your files to find more matches."))
                } else {
                    List {
                        ForEach(topics, id: \.self) { topic in
                            Section(topic) {
                                ForEach(preview.suggestions.filter { $0.topic == topic }) { suggestion in
                                    Toggle(isOn: Binding(get: { selection.contains(suggestion.id) }, set: { if $0 { selection.insert(suggestion.id) } else { selection.remove(suggestion.id) } })) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(suggestion.source.lastPathComponent).font(.body.weight(.medium)).foregroundStyle(.primary)
                                            Text("From: " + suggestion.source.path).lineLimit(1).truncationMode(.middle).help(suggestion.source.path)
                                            Label(suggestion.destination.deletingLastPathComponent().path.replacingOccurrences(of: preview.destination.path + "/", with: ""), systemImage: "arrow.turn.down.right").lineLimit(1).truncationMode(.middle).help(suggestion.destination.path)
                                            Button("Preview file…") { model.previewItem = BrowserItem(url: suggestion.source, isFolder: false, isPackage: false, size: 0, modified: .distantPast) }
                                                .buttonStyle(.borderless).help("Preview this file without opening another app")
                                            DisclosureGroup("Why this folder?") {
                                                Text(suggestion.evidence)
                                            }
                                        }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 5)
                                    }.toggleStyle(.checkbox).disabled(applying || analyzing)
                                }
                            }
                        }
                    }.listStyle(.inset)
                }
            } else {
                ContentUnavailableView("Organize by Content", systemImage: "square.stack.3d.up", description: Text("Find related work, study, travel, creative, home, shopping, event, and cooking files—even when they are scattered across different folders. Analysis leaves your files in place."))
            }
        }.padding(24).frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .task { if automaticallyAnalyze && preview == nil && !analyzing { analyze() } }
        .onDisappear { analysis?.cancel(); analysisID = UUID(); analyzing = false }
        .onChange(of: model.state.roots) {
            analysis?.cancel(); analysisID = UUID(); analyzing = false
            preview = nil; selection = []
            if automaticallyAnalyze { analyze() }
        }
    }

    private func analyze() {
        analyzing = true; preview = nil; selection = []
        model.status = "Analyzing indexed content for organization…"
        let id = UUID(); analysisID = id
        analysis = Task {
            defer { if analysisID == id { analyzing = false } }
            do {
                let result = try await model.library.previewSemanticOrganization(home: FileManager.default.homeDirectoryForCurrentUser)
                try Task.checkCancellation()
                preview = result
                model.status = "\(result.suggestions.count) organization suggestions. Files are unchanged."
            } catch is CancellationError { if analysisID == id { model.status = "Organization analysis cancelled. Files are unchanged." } }
            catch { model.error = error.localizedDescription }
        }
    }
    private func apply(_ plan: OrganizationPreview) {
        applying = true
        let selected = selection
        Task {
            defer { applying = false }
            do {
                let result = try await model.library.applySemanticOrganization(planID: plan.id, selected: selected)
                model.state = await model.library.current(); model.reloadFolder()
                model.status = "Organized \(result.moved) files by content."
                preview = nil; selection = []
                if !result.errors.isEmpty { model.error = result.errors.joined(separator: "\n") }
            } catch { model.error = error.localizedDescription; preview = nil; selection = [] }
        }
    }
}
