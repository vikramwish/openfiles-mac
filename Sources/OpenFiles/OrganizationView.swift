import SwiftUI
import OpenFilesCore

private typealias OrganizationState<Value> = SwiftUI.State<Value>

struct OrganizationView: View {
    @EnvironmentObject private var model: AppModel
    @OrganizationState private var preview: OrganizationPreview?
    @OrganizationState private var selection = Set<UUID>()
    @OrganizationState private var analyzing = false
    @OrganizationState private var applying = false
    @OrganizationState private var analysisID = UUID()
    @OrganizationState private var analysis: Task<Void, Never>?
    private var topics: [String] { Array(Set(preview?.suggestions.map(\.topic) ?? [])).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "folder.badge.gearshape").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text("A place for everything on your Mac").font(.title2.weight(.semibold))
                    Text("Group personal files by what they contain, across folders and file types. Review the suggestions, then move only the files you select.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Across this Mac", systemImage: "desktopcomputer").font(.headline)
                        Spacer()
                        Button("Indexing Activity…") { model.showingIndexing = true }
                    }
                    Text("Includes indexed files throughout your home folder and any additional locations below. Protected system folders, apps, recognized project contents, sensitive files, and uncertain matches stay in place.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text("\(model.state.files.count) files currently in the index").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Update Index") { model.startIndexing() }.disabled(model.indexing)
                        Button("Add Location…") { preview = nil; model.chooseOrganizationFolder() }
                    }
                    ForEach(model.state.roots, id: \.self) { root in
                        HStack {
                            Label(root.path, systemImage: "folder").lineLimit(1).truncationMode(.middle).help(root.path)
                            Spacer()
                            Button("Remove") { preview = nil; model.removeFolder(root) }.buttonStyle(.borderless)
                        }.font(.callout)
                    }
                }.padding(8)
            }.disabled(analyzing || applying)
            HStack {
                if analyzing {
                    ProgressView().controlSize(.small)
                    Text("Comparing content embeddings and checking files…").font(.callout)
                    Button("Cancel") { analysis?.cancel(); analyzing = false }
                } else {
                    Button(preview == nil ? "Analyze My Files" : "Analyze Again") { analyze() }.disabled(applying)
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
                    Text("\(preview.suggestions.count) suggestions from \(preview.indexedFiles) indexed files").font(.headline)
                    Text("Destination: \(preview.destination.path)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if preview.deferred > 0 {
                        Text("\(preview.deferred) more matches are waiting. Review up to 200 suggestions per pass, then analyze again.").font(.callout).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Why some files stay in place") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(preview.skipped.keys.sorted(), id: \.self) { reason in
                                Text("\(preview.skipped[reason] ?? 0) · \(reason)")
                            }
                            Text("Files not yet indexed are not analyzed. Similarity scores measure embedding distance; they are not probabilities. Filename-only embeddings are excluded.")
                        }.font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                    }
                }
                if !preview.modelAvailable {
                    ContentUnavailableView("Content Model Unavailable", systemImage: "exclamationmark.magnifyingglass", description: Text("The local embedding model could not load. Check indexing activity and try again."))
                } else if preview.suggestions.isEmpty {
                    ContentUnavailableView("No Clear Matches Yet", systemImage: "checklist", description: Text("Update the index to include more content. Files with ambiguous topics stay in their current folders."))
                } else {
                    List {
                        ForEach(topics, id: \.self) { topic in
                            Section(topic) {
                                ForEach(preview.suggestions.filter { $0.topic == topic }) { suggestion in
                                    Toggle(isOn: Binding(get: { selection.contains(suggestion.id) }, set: { if $0 { selection.insert(suggestion.id) } else { selection.remove(suggestion.id) } })) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(suggestion.source.lastPathComponent).font(.body.weight(.medium))
                                            Text("From: " + suggestion.source.path).lineLimit(1).truncationMode(.middle).help(suggestion.source.path)
                                            Label(suggestion.destination.path, systemImage: "arrow.turn.down.right").lineLimit(1).truncationMode(.middle).help(suggestion.destination.path)
                                            Text(String(format: "Content similarity %.2f · lead over next topic %.2f", suggestion.similarity, suggestion.margin))
                                            Text(suggestion.evidence).lineLimit(2)
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
        }.padding(24)
        .onDisappear { analysis?.cancel() }
        .onChange(of: model.state.roots) { preview = nil; selection = [] }
    }

    private func analyze() {
        analyzing = true; preview = nil; selection = []
        let id = UUID(); analysisID = id
        analysis = Task {
            defer { if analysisID == id { analyzing = false } }
            do {
                let result = try await model.library.previewSemanticOrganization(home: FileManager.default.homeDirectoryForCurrentUser)
                try Task.checkCancellation()
                preview = result
            } catch is CancellationError { }
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
