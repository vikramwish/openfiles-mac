import SwiftUI
import AppKit
import OpenFilesCore

typealias CollectionModelState<Value> = SwiftUI.State<Value>

@MainActor
final class CollectionsModel: ObservableObject {
    @Published private(set) var collections: [FileCollection] = []
    @Published private(set) var busy = false
    @Published var error: String?
    private let store: CollectionStore
    private var loaded = false
    init(directory: URL) { store = CollectionStore(directory: directory) }
    func load() async {
        guard !loaded else { return }
        do { collections = try await store.load(); loaded = true }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func create(_ title: String, files: [URL] = []) async -> UUID? {
        guard !busy else { return nil }
        busy = true; defer { busy = false }
        do {
            let collection = try await store.create(title: title, files: files)
            collections = try await store.load(); loaded = true
            return collection.id
        } catch { self.error = error.localizedDescription; return nil }
    }
    private func run(_ action: @escaping (CollectionStore) async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action(store); collections = try await store.load() }
            catch { self.error = error.localizedDescription }
        }
    }
    func add(_ urls: [URL], to id: UUID) { run { try await $0.add(urls, to: id) } }
    func remove(_ url: URL, from id: UUID) { run { try await $0.remove(url, from: id) } }
    func renameAndWait(_ id: UUID, title: String) async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        do {
            try await store.rename(id, title: title); collections = try await store.load()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func locate(_ missing: URL, in id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Locate \(missing.lastPathComponent)"
        panel.message = "Choose its current location to update this reference. No files will be moved."
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try await $0.replace(missing, with: url, in: id) }
    }
    func delete(_ id: UUID) { run { try await $0.delete(id) } }
    func chooseFiles(for id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Add to collection"
        panel.message = "Files and folders stay in their original locations. Only references are saved."
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls, to: id)
    }
}

struct CollectionNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let heading: String
    @CollectionModelState var name: String = ""
    let submit: (String) async -> Bool
    @CollectionModelState private var saving = false
    @CollectionModelState private var failed = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(heading).font(.title2.weight(.semibold))
            TextField("Collection name", text: $name).textFieldStyle(.roundedBorder)
                .focused($focused).onSubmit { save() }
            Text("Bring related files together while keeping them in their original locations.")
                .font(.callout).foregroundStyle(.secondary)
            if failed { Text("Couldn’t save the collection. Check the name and try again.").font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120)
            }
        }.padding(24).frame(width: 400).disabled(saving).onAppear { focused = true }
    }
    private func save() {
        guard !saving, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else { return }
        saving = true
        Task { if await submit(name) { dismiss() } else { failed = true }; saving = false }
    }
}

/// Used by both search results and the browser, including before the first collection exists.
struct AddToCollectionMenu: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var collections: CollectionsModel
    let urls: [URL]
    @CollectionModelState private var creating = false
    var body: some View {
        Menu {
            ForEach(collections.collections) { collection in
                Button(collection.title) { collections.add(urls, to: collection.id) }
            }
            if !collections.collections.isEmpty { Divider() }
            Button("New collection…") { creating = true }
        } label: { Label("Add to collection", systemImage: "folder.badge.plus") }
        .disabled(collections.busy || urls.isEmpty)
        .sheet(isPresented: $creating) {
            CollectionNameSheet(heading: "New collection") { title in
                guard let id = await collections.create(title, files: urls) else { return false }
                model.selectedCollectionID = id; model.section = .collections; model.query = ""
                return true
            }
        }
    }
}


extension FileCollection {
    var referenceCountLabel: String { files.count == 1 ? "1 reference" : "\(files.count) references" }
}
