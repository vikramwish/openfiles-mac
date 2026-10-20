import SwiftUI
import AppKit
import OpenFilesCore

@MainActor
final class AppModel: ObservableObject {
    @Published var state = LibraryState()
    @Published var results: [FileRecord] = []
    @Published var proposals: [MoveProposal] = []
    @Published var vaultState = VaultState(exists: false, mounted: false)
    @Published var query = "" { didSet { search() } }
    @Published var busy = false
    @Published var status = "Your files. A little more findable."
    @Published var error: String?
    @Published var embeddingsAvailable = false
    @Published var commitTarget: URL?
    @Published var showingCommit = false
    @Published var section: Section = .files
    let library: FileLibrary
    let vault: EncryptedVault
    private var started = false
    private var searchTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    enum Section: String, CaseIterable, Identifiable {
        case files = "All files", organize = "Organize", history = "Version history", vault = "Private vault"
        var id: String { rawValue }
        var icon: String { switch self { case .files: "square.grid.2x2"; case .organize: "tray.2"; case .history: "clock.arrow.circlepath"; case .vault: "lock.shield" } }
        var subtitle: String { switch self { case .files: "Find the file you’re thinking of."; case .organize: "A place for everything, with you in control."; case .history: "Keep the moments that matter."; case .vault: "An encrypted home for private files." } }
    }
    init(directory: URL? = nil) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenFiles", isDirectory: true)
        library = FileLibrary(directory: folder); vault = EncryptedVault(directory: folder)
    }
    func start() async {
        guard !started else { return }; started = true
        await perform {
            self.state = try await self.library.load()
            self.vaultState = await self.vault.status()
            if !self.state.roots.isEmpty { try await self.scan() }
        }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                if self.state.autoOrganize && !self.busy {
                    await self.perform {
                        try await self.scan()
                        _ = try await self.library.previewOrganization()
                        let report = try await self.library.applyOrganization()
                        self.state = await self.library.current(); self.search()
                        self.status = "Automatically organized \(report.moved) files."
                        if !report.errors.isEmpty { self.error = report.errors.joined(separator: "\n") }
                    }
                }
            }
        }
    }
    func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await action() } catch { self.error = error.localizedDescription }
    }
    func scan() async throws {
        let report = try await library.scan()
        state = report.state; embeddingsAvailable = report.embeddingsAvailable; proposals = []; search()
        status = "\(state.files.count) files indexed locally" + (report.skipped > 0 ? " · \(report.skipped) unreadable or over the 2,000-file limit" : "")
    }
    func refresh() { Task { await perform { try await self.scan() } } }
    private func search() {
        searchTask?.cancel()
        let text = query
        searchTask = Task {
            if !text.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled else { return }
            let found = await library.search(text)
            guard !Task.isCancelled else { return }
            results = found
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.title = "Add a folder to OpenFiles"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await perform { try await self.library.addRoot(url); try await self.scan() } }
    }
    func removeFolder(_ url: URL) {
        Task { await perform { try await self.library.removeRoot(url); self.state = await self.library.current(); self.proposals = []; self.search() } }
    }
    func open(_ file: FileRecord, reveal: Bool = false) {
        Task { await perform {
            let url = try await self.library.authorized(file.url)
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { try await NSWorkspace.shared.open(url, configuration: .init()) }
        } }
    }
    func chooseCommit(project: Bool = false) {
        let panel = NSOpenPanel(); panel.title = "Commit a saved file or project"; panel.message = "Save in your editor first. OpenFiles snapshots the saved file on disk."; panel.canChooseDirectories = project; panel.canChooseFiles = !project; panel.treatsFilePackagesAsDirectories = project
        guard panel.runModal() == .OK, let url = panel.url else { return }
        commitTarget = url; showingCommit = true
        NSApp.activate(ignoringOtherApps: true)
    }
    func prepareCommit(_ file: FileRecord) { commitTarget = file.url; showingCommit = true }
    func commit(message: String) {
        guard let target = commitTarget else { return }
        Task { await perform {
            self.state = try await self.library.commit(target, message: message)
            self.showingCommit = false; self.commitTarget = nil; self.status = "Version saved for \(target.lastPathComponent)."
        } }
    }
    func export(_ version: FileVersion) {
        let panel = NSOpenPanel(); panel.title = "Export a restored copy"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await perform {
            let result = try await self.library.exportVersion(version, into: url)
            NSWorkspace.shared.activateFileViewerSelecting([result]); self.status = "Restored a new copy. Your working file is unchanged."
        } }
    }
    func preview() { Task { await perform { self.proposals = try await self.library.previewOrganization(); self.status = self.proposals.isEmpty ? "No eligible files. Files must be at the folder’s top level and unchanged for 10 seconds." : "Review \(self.proposals.count) proposed moves." } } }
    func applyMoves() { Task { await perform {
        let report = try await self.library.applyOrganization(); self.state = await self.library.current(); self.proposals = []; self.search()
        self.status = "Organized \(report.moved) files."
        if !report.errors.isEmpty { self.error = report.errors.joined(separator: "\n") }
    } } }
    func setAutomatic(_ enabled: Bool) { Task { await perform { try await self.library.setAutoOrganize(enabled); self.state = await self.library.current() } } }
    func vaultAction(password: String) { Task { await perform {
        if self.vaultState.exists { self.vaultState = try await self.vault.unlock(password: password) }
        else { self.vaultState = try await self.vault.create(password: password) }
        self.status = "Vault unlocked. Lock it when you’re done."
    } } }
    func lockVault() { Task { await perform { self.vaultState = try await self.vault.lock(); self.status = "Vault locked." } } }
    func openVault() { Task { await perform { let url = try await self.vault.mountedURL(); try await NSWorkspace.shared.open(url, configuration: .init()) } } }
    func importVault() {
        let panel = NSOpenPanel(); panel.title = "Copy a file into your vault"; panel.message = "The original remains in place. After checking the encrypted copy, remove the original yourself."; panel.canChooseFiles = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await perform { _ = try await self.vault.importCopy(url); self.status = "Encrypted copy saved. The original still exists outside the vault." } }
    }
    func addSamples() { Task { await perform {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFiles Sample \(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let samples = ["Product launch.md": "A launch plan for a new creative application. Marketing milestones, release checklist, and customer feedback from beta testing.", "Weekend in Kyoto.txt": "Travel itinerary for Japan. Temples, gardens, train tickets, a walking tour, and places to visit in Kyoto.", "Studio budget.csv": "Item,Cost\nMicrophone,240\nAudio interface,180\nStudio headphones,120", "Brand direction.txt": "Visual identity exploration. Minimal typography, warm neutral colors, and a modern wordmark for the design studio."]
        for (name, content) in samples {
            let file = root.appendingPathComponent(name); try content.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: file.path)
        }
        try await self.library.addRoot(root); try await self.scan()
    } } }
}
