import SwiftUI
import AppKit
import OpenFilesCore

private typealias CollectionViewState<Value> = SwiftUI.State<Value>

struct CollectionsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var collections: CollectionsModel
    @CollectionViewState private var creating = false
    @CollectionViewState private var renaming: FileCollection?
    @CollectionViewState private var deleting: FileCollection?
    private var selected: FileCollection? { collections.collections.first { $0.id == model.selectedCollectionID } }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Collections").font(.headline)
                    Spacer()
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New collection").disabled(collections.busy)
                }.padding(16)
                Divider()
                if collections.collections.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Bring related files together").font(.headline)
                        Text("Create a collection for a project, trip, or anything you’re working on.").foregroundStyle(.secondary)
                        Button("New collection") { creating = true }.disabled(collections.busy)
                    }.padding(16)
                    Spacer()
                } else {
                    List(selection: $model.selectedCollectionID) {
                        ForEach(collections.collections) { collection in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(collection.title, systemImage: "rectangle.stack").lineLimit(2)
                                Text(collection.referenceCountLabel).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4).tag(collection.id)
                            .contextMenu {
                                Button("Rename…") { renaming = collection }
                                Button("Remove collection…", role: .destructive) { deleting = collection }
                            }
                        }
                    }
                }
            }.frame(minWidth: 200, idealWidth: 230, maxWidth: 260)
            Group {
                if let selected {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(selected.title).font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                                Text("References only · originals stay in their folders").font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add files…", systemImage: "plus") { collections.chooseFiles(for: selected.id) }.disabled(collections.busy)
                            Menu {
                                Button("Rename…") { renaming = selected }
                                Button("Remove collection…", role: .destructive) { deleting = selected }
                            } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Collection actions")
                        }.padding(20)
                        Divider()
                        CollectionFilesView(collection: selected, collections: collections).id(selected.id)
                    }
                } else {
                    ContentUnavailableView("Choose a collection", systemImage: "rectangle.stack", description: Text("Add files from search results or choose files from any folder. A file can belong to more than one collection."))
                }
            }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $creating) {
            CollectionNameSheet(heading: "New collection") { title in
                guard let id = await collections.create(title) else { return false }
                model.selectedCollectionID = id
                return true
            }
        }
        .sheet(item: $renaming) { collection in
            CollectionNameSheet(heading: "Rename collection", name: collection.title) { title in
                await collections.renameAndWait(collection.id, title: title)
            }
        }
        .confirmationDialog("Remove collection?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let deleting {
                Button("Remove collection", role: .destructive) { collections.delete(deleting.id); self.deleting = nil }
            }
        } message: { Text("Only the collection and its references will be removed. Original files stay where they are.") }
    }
}

private struct CollectionFilesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let collection: FileCollection
    @ObservedObject var collections: CollectionsModel
    @CollectionViewState private var items: [BrowserItem] = []
    @CollectionViewState private var selection: URL?
    @CollectionViewState private var loading = true
    @CollectionViewState private var refreshID = UUID()
    @FocusState private var focused: Bool
    private struct RefreshKey: Equatable {
        let collection: FileCollection
        let request: UUID
    }
    private var selected: BrowserItem? { items.first { $0.url == selection } }
    var body: some View {
        VStack(spacing: 0) {
            if collection.files.isEmpty {
                ContentUnavailableView {
                    Label("Add the files you need", systemImage: "doc.on.doc")
                } description: {
                    Text("Choose files from different folders, or find a file on Home and use Add to collection.")
                } actions: {
                    Button("Add files…") { collections.chooseFiles(for: collection.id) }.disabled(collections.busy)
                    Button("Find files") { model.query = ""; model.section = .home }
                }
            } else {
                HStack {
                    Text(collection.referenceCountLabel).foregroundStyle(.secondary)
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    if let selection {
                        Button("Remove reference", systemImage: "minus.circle") { collections.remove(selection, from: collection.id) }
                            .disabled(collections.busy)
                    }
                }.font(.callout).padding(12)
                GeometryReader { geometry in
                    if geometry.size.width >= 680 {
                        HSplitView {
                            fileList.frame(minWidth: 320)
                            InlineBrowserPreview(item: selected).frame(minWidth: 260, idealWidth: 300)
                        }
                    } else { fileList }
                }
                if let selection {
                    HStack {
                        if let selected {
                            Button("Open") { model.open(selected) }
                            Button("Quick Look") { model.previewItem = selected }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([selection]) }
                        } else {
                            Text("Missing or inaccessible. The reference is kept so you can reconnect it.").foregroundStyle(.secondary)
                            Button("Locate…") { collections.locate(selection, in: collection.id) }
                        }
                        Spacer(minLength: 0)
                    }.font(.callout).padding(12)
                }
            }
        }
        .task(id: RefreshKey(collection: collection, request: refreshID)) { await refresh() }
        .onChange(of: scenePhase) { if scenePhase == .active { refreshID = UUID() } }
    }
    private var fileList: some View {
        List(selection: $selection) {
            ForEach(collection.files, id: \.self) { url in
                let item = items.first { $0.url == url }
                HStack(spacing: 10) {
                    Image(systemName: item == nil ? "doc.badge.ellipsis" : item?.isFolder == true ? "folder" : "doc")
                        .foregroundStyle(item == nil ? Color.secondary : Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(url.lastPathComponent).lineLimit(1)
                        Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if item == nil { Text(loading ? "Checking availability…" : "Missing or inaccessible").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 5).tag(url).help(url.path)
                .onTapGesture(count: 2) { if let item { model.open(item) } }
                .contextMenu {
                    if let item {
                        Button("Open") { model.open(item) }
                        Button("Quick Look") { model.previewItem = item }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    } else { Button("Locate…") { collections.locate(url, in: collection.id) } }
                    Divider()
                    Button("Remove reference") { collections.remove(url, from: collection.id) }.disabled(collections.busy)
                }
            }
        }
        .focused($focused)
        .onKeyPress(.return) { if let selected { model.open(selected) }; return .handled }
        .onKeyPress(.space) { if let selected { model.previewItem = selected }; return .handled }
    }
    private func refresh() async {
        loading = true
        let loaded = await model.browser.items(at: collection.files)
        guard !Task.isCancelled else { return }
        items = loaded; loading = false
        if let selection, !collection.files.contains(selection) { self.selection = nil }
    }
}

struct CollectionErrorPresenter: View {
    @ObservedObject var collections: CollectionsModel
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .alert("Couldn’t update collections", isPresented: Binding(get: { collections.error != nil }, set: { if !$0 { collections.error = nil } })) {
                Button("OK") { collections.error = nil }
            } message: { Text(collections.error ?? "") }
    }
}
