import SwiftUI
import OpenFilesCloud

private typealias CloudSearchState<Value> = SwiftUI.State<Value>

@MainActor
struct CloudSearchView: View {
    @ObservedObject var model: CloudBrowserModel
    @Environment(\.dismiss) private var dismiss
    @CloudSearchState private var query = ""
    @CloudSearchState private var submitted = ""
    @CloudSearchState private var items: [CloudItem] = []
    @CloudSearchState private var cursor: CloudSearchCursor?
    @CloudSearchState private var kind: CloudSearchKind = .all
    @CloudSearchState private var sort: CloudSearchSort = .provider
    @CloudSearchState private var loading = false
    @CloudSearchState private var error: String?
    @CloudSearchState private var task: Task<Void, Never>?
    @CloudSearchState private var generation = UUID()
    @FocusState private var searchFocused: Bool
    private var visible: [CloudItem] { CloudSearchResults.visible(items, kind: kind, sort: sort) }
    private var location: FileStorageLocation { .remote(provider: model.provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Search \(model.provider.displayName)").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("Search cloud files…", text: $query).textFieldStyle(.roundedBorder)
                    .focused($searchFocused).onSubmit { search(append: false) }
                Button("Search") { search(append: false) }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.connected)
                if loading { ProgressView().controlSize(.small); Button("Stop") { stop() } }
            }
            Text(model.provider == .googleDrive
                 ? "Search filenames across this account. Your search is sent to Google Drive."
                 : "Search this drive using OneDrive’s index, which can match names and contents. Your search is sent to OneDrive.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("File type", selection: $kind) { ForEach(CloudSearchKind.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Sort", selection: $sort) { ForEach(CloudSearchSort.allCases) { Text($0.rawValue).tag($0) } }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack(spacing: 0) {
                results
                if let item = model.previewItem {
                    Divider()
                    CloudPreviewView(model: model, item: item).frame(width: 330)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(submitted.isEmpty ? "No search yet" : "\(visible.count) shown · \(items.count) loaded for “\(submitted)”")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if cursor != nil {
                    Button("Load more") { search(append: true) }.disabled(loading)
                }
            }
            Text("Filters and sorting apply to loaded results. Provider indexing may be incomplete. Preview downloads a temporary copy; search itself only retrieves metadata.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 900, height: 620)
        .onAppear { model.dismissCloudPreview(); searchFocused = true }
        .onDisappear { stop(); model.dismissCloudPreview() }
        .onChange(of: model.connectionID) { dismiss() }
        .onChange(of: model.connected) { if !model.connected { dismiss() } }
    }

    @ViewBuilder private var results: some View {
        if visible.isEmpty {
            ContentUnavailableView(submitted.isEmpty ? "Find your cloud files" : loading ? "Searching…" : "No matching files",
                                   systemImage: "magnifyingglass",
                                   description: Text(submitted.isEmpty ? "Enter a filename or phrase to start." : cursor != nil ? "Try another filter or load more results." : "Try another search or file type."))
        } else {
            List(visible) { item in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(item.name).font(.headline).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        if let size = item.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                    }
                    HStack {
                        FileLocationTag(location: location)
                        if let date = item.modified { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                    }
                    HStack {
                        if CloudPreviewPolicy.supports(item) {
                            Button("Preview") { model.preview(item, location: location) }
                        }
                        if item.canDownload { Button("Save copy…") { model.saveCopy(item) }.disabled(model.transferBusy) }
                        if item.webURL != nil { Button("Open in browser") { model.openOnWeb(item) } }
                    }.controlSize(.small)
                }.padding(.vertical, 5)
            }.listStyle(.inset)
        }
    }

    private func stop() {
        task?.cancel(); generation = UUID(); loading = false
    }
    private func search(append: Bool) {
        let text = append ? submitted : query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, model.connected, !append || cursor != nil else { return }
        stop(); let request = generation, next = append ? cursor : nil
        if !append { items = []; cursor = nil; submitted = text; model.dismissCloudPreview() }
        loading = true; error = nil
        task = Task {
            defer { if generation == request { loading = false } }
            do {
                let page = try await model.search(text, cursor: next)
                guard !Task.isCancelled, generation == request else { return }
                items = CloudSearchResults.visible(items + page.items)
                cursor = page.next
            } catch is CancellationError { }
            catch { if generation == request { self.error = error.localizedDescription } }
        }
    }
}
