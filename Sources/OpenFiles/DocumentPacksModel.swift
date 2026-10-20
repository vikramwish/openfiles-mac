import SwiftUI
import AppKit
import OpenFilesCore

/// Shared across workspace windows; all file reads and writes stay in the store actor.
@MainActor
final class DocumentPacksModel: ObservableObject {
    @Published private(set) var packs: [DocumentPack] = []
    @Published var selectedID: UUID? { didSet { if oldValue != selectedID { exportedURL = nil } } }
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var exportedURL: URL?
    let store: DocumentPackStore
    var selected: DocumentPack? { packs.first { $0.id == selectedID } }
    init(directory: URL) { store = DocumentPackStore(directory: directory) }
    func load() async {
        do { packs = try await store.load() } catch { self.error = error.localizedDescription }
    }
    func run(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; exportedURL = nil
        Task {
            defer { busy = false }
            do { try await action(); packs = try await store.load() }
            catch { self.error = error.localizedDescription; await load() }
        }
    }
    func create(_ template: DocumentPackTemplate) {
        let pack = template.makePack()
        run { try await self.store.save(pack); self.selectedID = pack.id; self.exportedURL = nil }
    }
    private func checkCurrent(_ pack: DocumentPack) throws {
        guard packs.first(where: { $0.id == pack.id }) == pack else {
            throw OpenFilesError.message("This checklist changed in another window. Reopen it and try again.")
        }
    }
    func save(_ pack: DocumentPack, replacing original: DocumentPack) {
        run { try self.checkCurrent(original); try await self.store.save(pack) }
    }
    func delete(_ pack: DocumentPack) {
        run { try self.checkCurrent(pack); try await self.store.delete(pack.id); if self.selectedID == pack.id { self.selectedID = nil } }
    }
    func chooseFiles(for item: DocumentPackItem, in pack: DocumentPack) {
        let picker = NSOpenPanel()
        picker.title = "Choose documents for \(item.title)"
        picker.message = "Files stay in their original locations. Review each file before exporting a copy."
        picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK else { return }
        attach(picker.urls, to: item, in: pack)
    }
    func attach(_ urls: [URL], to item: DocumentPackItem, in pack: DocumentPack) {
        run {
            try self.checkCurrent(pack)
            var updated = pack
            for url in urls { updated = try await self.store.attach(url, to: item.id, in: updated) }
        }
    }
    func review(_ attachment: DocumentPackAttachment, in pack: DocumentPack) {
        run { try self.checkCurrent(pack); _ = try await self.store.review(attachment.id, in: pack) }
    }
    func remove(_ attachment: DocumentPackAttachment, in pack: DocumentPack) {
        run { try self.checkCurrent(pack); _ = try await self.store.removeAttachment(attachment.id, in: pack) }
    }
    func export(_ pack: DocumentPack) {
        let picker = NSOpenPanel()
        picker.title = "Export document pack"
        picker.message = "A new folder will contain reviewed copies and a checklist. Missing checklist items will be listed. Nothing is sent to anyone."
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.canCreateDirectories = true
        guard picker.runModal() == .OK, let directory = picker.url else { return }
        run { try self.checkCurrent(pack); self.exportedURL = try await self.store.export(pack, to: directory) }
    }
}
