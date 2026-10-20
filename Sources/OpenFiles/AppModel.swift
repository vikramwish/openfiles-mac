import SwiftUI
import AppKit
import Combine
import OpenFilesCore

@MainActor
final class AppModel: ObservableObject {
    @Published var state = LibraryState() {
        didSet { if !receivingSharedState { serviceOwner?.state = state } }
    }
    @Published var proposals: [MoveProposal] = [] {
        didSet { if !receivingSharedState { serviceOwner?.proposals = proposals } }
    }
    @Published var vaultState = VaultState(exists: false, mounted: false) {
        didSet { if !receivingSharedState { serviceOwner?.vaultState = vaultState } }
    }
    @Published var query = "" { didSet { search() } }
    @Published var busy = false
    @Published var status = "Your files. A little more findable."
    @Published var error: String?
    @Published var embeddingsAvailable = false
    @Published var section: Section = .home
    var showSearch: (() -> Void)?
    var showWorkspace: (() -> Void)?
    var newWorkspace: (() -> Void)?
    @Published var activeWorkspace: AppModel? {
        didSet {
            activeCommandChanges = activeWorkspace?.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
    private var activeCommandChanges: AnyCancellable?
    @Published var currentFolder = FileManager.default.homeDirectoryForCurrentUser
    @Published var browserItems: [BrowserItem] = []
    @Published var selectedURL: URL?
    @Published var folderError: String?
    @Published var loadingFolder = false
    @Published var indexing = false
    @Published var indexProgress = IndexProgress()
    @Published var indexSettings = IndexSettings()
    @Published var showingIndexing = false
    @Published var indexScopes: [URL] = []
    private var indexProgressTask: Task<Void, Never>?
    @Published var searchingSystem = false
    @Published var searchResultCount = 0
    @Published var searchThisFolder = false { didSet { search() } }
    @Published var showHidden = false { didSet { reloadFolder() } }
    @Published var showingGo = false
    @Published var pathInput = ""
    @Published var showingNewFolder = false
    @Published var newFolderName = ""
    @Published var previewItem: BrowserItem?
    @Published var editingURL: URL?
    @Published var syncStatus = "Loading local index"
    private var fileWatcher: FileEventWatcher?
    private var watchedRoots: [URL] = []
    private var pendingChanges = Set<URL>()
    private var needsReconciliation = false
    private var lastChange = Date.distantPast
    private var syncTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var versionPanel: NSPanel?

    func showVersionPanel(for url: URL) {
        editingURL = url
        if versionPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 660),
                                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "OpenFiles · Versions"
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.minSize = NSSize(width: 340, height: 460)
            let hosting = NSHostingView(rootView: EditingVersionsView().environmentObject(self))
            hosting.sizingOptions = []
            hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 660)
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            panel.setContentSize(NSSize(width: 380, height: 660))
            panel.center()
            versionPanel = panel
        }
        versionPanel?.orderFrontRegardless()
    }
    @Published var versionBusy = false {
        didSet { if !receivingSharedState { serviceOwner?.versionBusy = versionBusy } }
    }
    @Published var versionFocus = UUID()
    func reviewCommit(_ url: URL? = nil) {
        let target = url ?? selectedItem?.url ?? editingURL
        guard let target else { status = "Select a file to review and save its changes."; showWorkspace?(); return }
        editingURL = target
        navigate(to: target.deletingLastPathComponent())
        selectedURL = target
        versionFocus = UUID()
        showWorkspace?()
    }
    func commitChanges(_ review: VersionReview, selected: Set<String>, message: String) async throws {
        guard !versionBusy else { throw OpenFilesError.message("Another version operation is finishing. Try again shortly.") }
        versionBusy = true; defer { versionBusy = false }
        state = try await library.commitChanges(review, selected: selected, message: message)
        status = "Saved \(selected.count) changes · \(message)"
    }
    func cherryPick(_ review: VersionReview, selected: Set<String>, message: String) async throws {
        guard !versionBusy else { throw OpenFilesError.message("Another version operation is finishing. Try again shortly.") }
        versionBusy = true; defer { versionBusy = false }
        state = try await library.cherryPick(review, selected: selected, message: message)
        reloadFolder(); status = "Applied \(selected.count) selected changes. Recovery version saved automatically."
    }
    func restoreVersion(_ version: FileVersion, expectedDigest: String) async throws {
        guard !versionBusy else { throw OpenFilesError.message("Another version operation is finishing. Try again shortly.") }
        versionBusy = true; defer { versionBusy = false }
        state = try await library.restoreVersion(version.id, expectedDigest: expectedDigest)
        reloadFolder(); status = "Restored \(version.message). Previous saved work is in history."
    }
    func restoreSavedVersion(_ version: FileVersion) {
        Task {
            do {
                let review = try await library.reviewChanges(version.source)
                try await restoreVersion(version, expectedDigest: review.workingDigest)
            } catch { self.error = error.localizedDescription }
        }
    }
    let browser = FileBrowser()
    private let systemSearch = SystemSearch()
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
        return [("Home folder", "folder", home)] + [("Desktop", "menubar.dock.rectangle"), ("Documents", "doc.text"), ("Downloads", "arrow.down.circle"), ("Pictures", "photo"), ("Music", "music.note"), ("Movies", "film")].map { ($0.0, $0.1, home.appendingPathComponent($0.0, isDirectory: true)) } + [("Applications", "square.grid.2x2", URL(fileURLWithPath: "/Applications", isDirectory: true)), ("This Mac", "desktopcomputer", URL(fileURLWithPath: "/", isDirectory: true))]
    }
    var volumes: [URL] { FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes])?.filter { $0.path != "/" && !$0.path.hasPrefix("/System/") && !$0.path.contains("/OpenFiles/") } ?? [] }

    let library: FileLibrary
    let vault: EncryptedVault
    let packs: DocumentPacksModel
    let protection: ProtectionModel
    let cleanup: CleanupModel
    private let storageDirectory: URL
    private weak var serviceOwner: AppModel?
    private var receivingSharedState = false
    private var sharedSubscriptions = Set<AnyCancellable>()
    private var started = false
    private var searchTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    enum Section: String, CaseIterable, Identifiable {
        case cleanup = "Clean up"
        case home = "Home", packs = "Prepare documents", files = "Browse files", cloud = "Cloud storage", organize = "Organize", history = "Version history", protection = "Automatic versions", vault = "Private vault"
        var id: String { rawValue }
        var icon: String { switch self { case .cleanup: "sparkles.rectangle.stack"; case .home: "house"; case .packs: "checklist"; case .protection: "shield.lefthalf.filled"; case .files: "square.grid.2x2"; case .cloud: "cloud"; case .organize: "tray.2"; case .history: "clock.arrow.circlepath"; case .vault: "lock.shield" } }
        var subtitle: String { switch self { case .cleanup: "Review duplicates and files you may no longer need."; case .home: "Your files, ready for what’s next."; case .packs: "Get your paperwork ready."; case .protection: "Keep saved changes automatically."; case .files: "Find the file you’re thinking of."; case .cloud: "Browse Google Drive and OneDrive directly."; case .organize: "A place for everything, with you in control."; case .history: "Keep the moments that matter."; case .vault: "An encrypted home for private files." } }
    }
    init(directory: URL? = nil, sharing owner: AppModel? = nil) {
        let folder = directory ?? owner?.storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenFiles", isDirectory: true)
        storageDirectory = folder
        serviceOwner = owner
        library = owner?.library ?? FileLibrary(directory: folder)
        vault = owner?.vault ?? EncryptedVault(directory: folder)
        packs = owner?.packs ?? DocumentPacksModel(directory: folder.appendingPathComponent("DocumentPacks", isDirectory: true))
        protection = owner?.protection ?? ProtectionModel(library: library, directory: folder)
        cleanup = owner?.cleanup ?? CleanupModel(library: library, directory: folder)
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
        if let owner {
            mirror(owner.$state, to: \.state)
            mirror(owner.$proposals, to: \.proposals)
            mirror(owner.$vaultState, to: \.vaultState)
            mirror(owner.$versionBusy, to: \.versionBusy)
            mirror(owner.$indexing, to: \.indexing)
            mirror(owner.$indexProgress, to: \.indexProgress)
            mirror(owner.$indexSettings, to: \.indexSettings)
            mirror(owner.$indexScopes, to: \.indexScopes)
            mirror(owner.$embeddingsAvailable, to: \.embeddingsAvailable)
            mirror(owner.$syncStatus, to: \.syncStatus)
            showSearch = owner.showSearch
            owner.$state.map { $0.versions.count }.removeDuplicates().dropFirst().sink { [weak self] _ in
                self?.reloadFolder()
            }.store(in: &sharedSubscriptions)
            owner.$syncStatus.removeDuplicates().dropFirst().sink { [weak self] _ in
                self?.reloadFolder()
            }.store(in: &sharedSubscriptions)
        }
    }
    private func mirror<Value>(_ publisher: Published<Value>.Publisher, to keyPath: ReferenceWritableKeyPath<AppModel, Value>) {
        publisher.sink { [weak self] value in
            guard let self else { return }
            self.receivingSharedState = true
            self[keyPath: keyPath] = value
            self.receivingSharedState = false
        }.store(in: &sharedSubscriptions)
    }
    func closeWorkspace() {
        browseTask?.cancel(); searchTask?.cancel(); systemSearch.stop()
        versionPanel?.close(); versionPanel?.contentView = nil; versionPanel = nil
        sharedSubscriptions.removeAll()
    }
    func start() async {
        if serviceOwner != nil { return }
        guard !started else { return }; started = true
        navigate(to: currentFolder)
        section = .home
        await perform {
            self.state = try await self.library.load()
            await self.packs.load()
            self.protection.onLibraryChange = { [weak self] state in self?.state = state }
            await self.protection.start()
            if self.state.autoOrganize { try await self.library.setAutoOrganize(false); self.state = await self.library.current() }
            await self.library.enableDefaultDiscovery(home: FileManager.default.homeDirectoryForCurrentUser)
            self.vaultState = await self.vault.status()
            self.indexSettings = self.state.indexSettings ?? IndexSettings()
            self.indexProgress = self.library.indexMonitor.snapshot()
            self.indexScopes = await self.library.indexScopes()
        }
        indexProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.indexProgress = self.library.indexMonitor.snapshot()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        await startFileSync()
        if !indexSettings.paused { startIndexing() }
        pollingTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                ticks += 1
                if ticks % 5 == 0 && !self.indexing && !self.indexSettings.paused { self.queueSync([], reconcile: true) }

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
        if let serviceOwner { try await serviceOwner.scan(); return }
        indexing = true
        defer { indexing = false; indexProgress = library.indexMonitor.snapshot() }
        let report = try await library.scan()
        state = await library.current(); embeddingsAvailable = report.embeddingsAvailable; proposals = []; search()
        indexProgress = report.progress
        await startFileSync()
        status = "\(state.files.count) files in semantic catalog · \(report.progress.reused) reused · \(report.progress.embedded) newly embedded" + (report.progress.limitReached ? " · semantic limit reached" : "")
    }
    func startIndexing() {
        if let serviceOwner { serviceOwner.startIndexing(); return }
        guard !indexing, !indexSettings.paused else { return }
        indexing = true
        indexTask = Task {
            defer { indexing = false; indexProgress = library.indexMonitor.snapshot() }
            do { try await scan() } catch { status = "Semantic indexing paused: \(error.localizedDescription)" }
        }
    }
    func setIndexPaused(_ paused: Bool) {
        if let serviceOwner { serviceOwner.setIndexPaused(paused); return }
        Task {
            do {
                try await library.pauseIndexing(paused); indexSettings.paused = paused
                indexProgress = library.indexMonitor.snapshot()
                if !paused && !indexing { startIndexing() }
            } catch { self.error = error.localizedDescription }
        }
    }
    func stopIndexing() { Task { await library.cancelIndexing() } }
    func finishIndexingBeforeQuit() async {
        await protection.stop()
        fileWatcher?.stop(); pollingTask?.cancel(); indexProgressTask?.cancel(); syncTask?.cancel()
        pendingChanges = []; needsReconciliation = false
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        await library.cancelIndexing(); await syncTask?.value; await indexTask?.value; await library.waitForIndexingToStop()
    }
    private func startFileSync() async {
        let roots = await library.indexScopes()
        guard roots != watchedRoots else { return }
        watchedRoots = roots
        fileWatcher?.stop()
        let watcher = FileEventWatcher { [weak self] urls, overflow in
            Task { @MainActor in self?.queueSync(urls, reconcile: overflow) }
        }
        fileWatcher = watcher
        syncStatus = watcher.start(roots: roots) ? "Live sync" : "Watcher unavailable · periodic reconciliation"
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.queueSync([], reconcile: true) }
            }
        }
    }
    private func queueSync(_ urls: [URL], reconcile: Bool = false) {
        pendingChanges.formUnion(urls); needsReconciliation = needsReconciliation || reconcile
        if pendingChanges.count > 2000 { pendingChanges = []; needsReconciliation = true }
        lastChange = Date()
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { self.syncTask = nil }
            while !Task.isCancelled && (!pendingChanges.isEmpty || needsReconciliation) {
                do { try await Task.sleep(for: .milliseconds(800)) } catch { break }
                if Date().timeIntervalSince(lastChange) < 0.7 { continue }
                if indexSettings.paused { syncStatus = "Sync paused · changes queued"; continue }
                let libraryBusy = await library.indexingIsRunning()
                if indexing || libraryBusy { continue }
                if needsReconciliation {
                    needsReconciliation = false; startIndexing(); continue
                }
                let batch = pendingChanges; pendingChanges = []
                syncStatus = "Syncing changed files"
                do {
                    state = try await library.synchronizeChanges(Array(batch))
                    syncStatus = "Live sync · up to date"
                } catch {
                    if Task.isCancelled { break }
                    pendingChanges.formUnion(batch); syncStatus = "Changes queued · retrying sync"
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }
    func updateIndexSettings(_ settings: IndexSettings) {
        if let serviceOwner { serviceOwner.updateIndexSettings(settings); return }
        Task {
            do { try await library.configureIndexing(settings); indexSettings = settings; state = await library.current(); search() }
            catch { self.error = error.localizedDescription }
        }
    }
    func addIndexExclusion() {
        let panel = NSOpenPanel(); panel.title = "Exclude folder from semantic indexing"; panel.message = "The folder stays available in browsing and Spotlight search."; panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var settings = indexSettings
        if !settings.excludedFolders.contains(url) { settings.excludedFolders.append(url); updateIndexSettings(settings) }
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
            let found = await library.search(text)
            let urls = found.prefix(100).map(\.url).filter { !searchThisFolder || FileRules.contains(currentFolder, $0) }
            let items = await browser.items(at: urls)
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
        Task {
            do {
                _ = try await NSWorkspace.shared.open(item.url, configuration: .init())
                if !item.sensitive { self.showVersionPanel(for: item.url) }
            } catch { self.error = error.localizedDescription }
        }
    }
    func openSelected() { if let item = selectedItem { open(item) } }
    func previewSelected() { if let item = selectedItem { previewItem = item } }
    func prepareCommit(_ item: BrowserItem) { reviewCommit(item.url) }
    func createFolder() {
        Task { await perform {
            _ = try await self.browser.createFolder(in: self.currentFolder, name: self.newFolderName)
            self.showingNewFolder = false; self.newFolderName = ""; self.reloadFolder()
        } }
    }
    func chooseCommit(project: Bool = false) {
        if selectedItem != nil || editingURL != nil { reviewCommit(); return }
        let panel = NSOpenPanel(); panel.title = "Choose a file to version"; panel.canChooseDirectories = project; panel.canChooseFiles = !project; panel.treatsFilePackagesAsDirectories = project
        guard panel.runModal() == .OK, let url = panel.url else { return }
        reviewCommit(url)
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
