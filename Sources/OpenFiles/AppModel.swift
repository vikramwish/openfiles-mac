import SwiftUI
import AppKit
import OpenFilesCore

@MainActor
final class AppModel: ObservableObject {
    @Published var state = LibraryState()
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
    @Published var currentFolder = FileManager.default.homeDirectoryForCurrentUser
    @Published var browserItems: [BrowserItem] = []
    @Published var selectedURL: URL?
    @Published var folderError: String?
    @Published var loadingFolder = false
    @Published var indexing = false
    @Published var searchingSystem = false
    @Published var searchResultCount = 0
    @Published var searchThisFolder = false { didSet { search() } }
    @Published var showHidden = false { didSet { reloadFolder() } }
    @Published var showingGo = false
    @Published var pathInput = ""
    @Published var showingNewFolder = false
    @Published var newFolderName = ""
    @Published var previewItem: BrowserItem?
    let browser = FileBrowser()
    private let systemSearch = SystemSearch()
    private let semanticService = SemanticSearchService.shared
    private var folderItems: [BrowserItem] = []
    private var spotlightItems: [BrowserItem] = []
    private var semanticItems: [BrowserItem] = []
    private var history: [URL] = []
    private var historyIndex = -1
    private var browseTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var systemUpdateGeneration = UUID()
    private var searchGeneration = UUID()
    private var browseGeneration = UUID()
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }
    var canGoUp: Bool { currentFolder.path != "/" }
    var selectedItem: BrowserItem? { browserItems.first { $0.url == selectedURL } }
    var locations: [(name: String, icon: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [("Home", "house", home)] + [("Desktop", "menubar.dock.rectangle"), ("Documents", "doc.text"), ("Downloads", "arrow.down.circle"), ("Pictures", "photo"), ("Music", "music.note"), ("Movies", "film")].map { ($0.0, $0.1, home.appendingPathComponent($0.0, isDirectory: true)) } + [("Applications", "square.grid.2x2", URL(fileURLWithPath: "/Applications", isDirectory: true)), ("This Mac", "desktopcomputer", URL(fileURLWithPath: "/", isDirectory: true))]
    }
    var volumes: [URL] { FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes])?.filter { $0.path != "/" && !$0.path.hasPrefix("/System/") && !$0.path.contains("/OpenFiles/") } ?? [] }

    let library: FileLibrary
    let vault: EncryptedVault
    private var started = false
    private var searchTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    enum Section: String, CaseIterable, Identifiable {
        case files = "Files", organize = "Organize", history = "Version history", vault = "Private vault"
        var id: String { rawValue }
        var icon: String { switch self { case .files: "square.grid.2x2"; case .organize: "tray.2"; case .history: "clock.arrow.circlepath"; case .vault: "lock.shield" } }
        var subtitle: String { switch self { case .files: "Find the file you’re thinking of."; case .organize: "A place for everything, with you in control."; case .history: "Keep the moments that matter."; case .vault: "An encrypted home for private files." } }
    }
    init(directory: URL? = nil) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenFiles", isDirectory: true)
        library = FileLibrary(directory: folder); vault = EncryptedVault(directory: folder)
        systemSearch.onUpdate = { [weak self] urls, gathering, count in
            guard let self, !self.query.isEmpty else { return }
            let token = self.searchGeneration, update = UUID()
            self.systemUpdateGeneration = update
            self.searchingSystem = gathering; self.searchResultCount = count
            Task {
                let visible = urls.filter { !FileRules.contains(folder, $0) && (self.showHidden || !$0.pathComponents.contains(where: { $0.hasPrefix(".") })) }
                let items = await self.browser.items(at: visible)
                guard self.searchGeneration == token, self.systemUpdateGeneration == update else { return }
                self.spotlightItems = items; self.mergeSearchResults()
            }
        }
    }
    func start() async {
        guard !started else { return }; started = true
        navigate(to: currentFolder)
        await perform {
            self.state = try await self.library.load()
            await self.library.enableDefaultDiscovery(home: FileManager.default.homeDirectoryForCurrentUser)
            self.vaultState = await self.vault.status()
        }
        startIndexing()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                if self.state.autoOrganize && !self.busy {
                    await self.perform {
                        try await self.scan()
                        _ = try await self.library.previewOrganization()
                        let report = try await self.library.applyOrganization()
                        self.state = await self.library.current(); self.reloadFolder(); self.search()
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
    func startIndexing() {
        guard !indexing else { return }
        indexing = true
        indexTask = Task {
            defer { indexing = false }
            do { try await scan() } catch { status = "Semantic indexing paused: \(error.localizedDescription)" }
        }
    }
    func refresh() { reloadFolder(); startIndexing() }
    func navigate(to folder: URL, recordHistory: Bool = true) {
        section = .files; query = ""; selectedURL = nil; folderError = nil
        currentFolder = folder.standardizedFileURL
        if recordHistory {
            history = Array(history.prefix(historyIndex + 1))
            history.append(currentFolder); historyIndex = history.count - 1
        }
        reloadFolder()
    }
    func reloadFolder() {
        browseTask?.cancel(); let generation = UUID(); browseGeneration = generation
        let folder = currentFolder, hidden = showHidden
        loadingFolder = true
        browseTask = Task {
            do {
                let items = try await browser.contents(of: folder, showHidden: hidden)
                guard !Task.isCancelled, browseGeneration == generation else { return }
                folderItems = items; folderError = nil
                if query.isEmpty { browserItems = items }
                status = "\(items.count) items · \(folder.path)"
            } catch {
                guard !Task.isCancelled, browseGeneration == generation else { return }
                folderItems = []; browserItems = []; folderError = error.localizedDescription
            }
            loadingFolder = false
        }
    }
    func back() { guard canGoBack else { return }; historyIndex -= 1; navigate(to: history[historyIndex], recordHistory: false) }
    func forward() { guard canGoForward else { return }; historyIndex += 1; navigate(to: history[historyIndex], recordHistory: false) }
    func up() { if canGoUp { navigate(to: currentFolder.deletingLastPathComponent()) } }
    func goToPath() {
        let path = (pathInput as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { error = "Enter an absolute path or a path starting with ~."; return }
        showingGo = false; navigate(to: URL(fileURLWithPath: path, isDirectory: true))
    }
    func requestGo() { pathInput = currentFolder.path; showingGo = true }
    private func search() {
        searchTask?.cancel(); systemSearch.stop(); searchGeneration = UUID()
        spotlightItems = []; semanticItems = []; searchingSystem = false; searchResultCount = 0
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines), token = searchGeneration
        guard !text.isEmpty else { browserItems = folderItems; return }
        // Local filename matches appear immediately, even before Spotlight finishes gathering.
        spotlightItems = folderItems.filter { $0.name.localizedCaseInsensitiveContains(text) }; mergeSearchResults()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, searchGeneration == token else { return }
            searchingSystem = true
            systemSearch.search(text, folder: searchThisFolder ? currentFolder : nil)
            // Hybrid semantic results: the local BGE/SigLIP2 service covers
            // documents, photos and videos; the built-in NLEmbedding index is
            // the English-text fallback. Service results come first.
            var urls = await semanticService.search(text)
            let found = await library.search(text)
            urls.append(contentsOf: found.map(\.url))
            let scoped = urls.filter { !searchThisFolder || FileRules.contains(currentFolder, $0) }
            let items = await browser.items(at: Array(scoped.prefix(150)))
            guard !Task.isCancelled, searchGeneration == token else { return }
            semanticItems = items; mergeSearchResults()
        }
    }
    private func mergeSearchResults() {
        var seen = Set<String>()
        browserItems = (semanticItems + spotlightItems).filter { seen.insert($0.url.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.title = "Open location"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        navigate(to: url)
    }
    func chooseOrganizationFolder() {
        let panel = NSOpenPanel(); panel.title = "Choose a folder to organize"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await perform { try await self.library.addRoot(url); try await self.scan() } }
    }
    func removeFolder(_ url: URL) {
        Task { await perform { try await self.library.removeRoot(url); self.state = await self.library.current(); self.proposals = []; self.search() } }
    }
    func open(_ item: BrowserItem, reveal: Bool = false) {
        if reveal { navigate(to: item.url.deletingLastPathComponent()); selectedURL = item.url; return }
        if item.isFolder { navigate(to: item.url); return }
        Task { do { _ = try await NSWorkspace.shared.open(item.url, configuration: .init()) } catch { self.error = error.localizedDescription } }
    }
    func openSelected() { if let item = selectedItem { open(item) } }
    func previewSelected() { if let item = selectedItem { previewItem = item } }
    func prepareCommit(_ item: BrowserItem) { commitTarget = item.url; showingCommit = true }
    func createFolder() {
        Task { await perform {
            _ = try await self.browser.createFolder(in: self.currentFolder, name: self.newFolderName)
            self.showingNewFolder = false; self.newFolderName = ""; self.reloadFolder()
        } }
    }
    func chooseCommit(project: Bool = false) {
        let panel = NSOpenPanel(); panel.title = "Commit a saved file or project"; panel.message = "Save in your editor first. OpenFiles snapshots the saved file on disk."; panel.canChooseDirectories = project; panel.canChooseFiles = !project; panel.treatsFilePackagesAsDirectories = project
        guard panel.runModal() == .OK, let url = panel.url else { return }
        commitTarget = url; showingCommit = true
        NSApp.activate(ignoringOtherApps: true)
    }
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
            self.navigate(to: result.deletingLastPathComponent()); self.selectedURL = result; self.status = "Restored a new copy. Your working file is unchanged."
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
    func openVault() { Task { await perform { let url = try await self.vault.mountedURL(); self.navigate(to: url) } } }
    func importVault() {
        let panel = NSOpenPanel(); panel.title = "Copy a file into your vault"; panel.message = "The original remains in place. After checking the encrypted copy, remove the original yourself."; panel.canChooseFiles = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await perform { _ = try await self.vault.importCopy(url); self.status = "Encrypted copy saved. The original still exists outside the vault." } }
    }
}
