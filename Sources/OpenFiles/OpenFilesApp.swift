import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model: AppModel
    private var searchPanel: SearchPanelController?
    private let smokeRoot: URL?
    private var smokeWindow: NSWindow?

    override init() {
        if let path = ProcessInfo.processInfo.environment["OPENFILES_UI_SMOKE_ROOT"] ?? Bundle.main.object(forInfoDictionaryKey: "OpenFilesUISmokeRoot") as? String {
            let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            let temporaryRoots = [URL(fileURLWithPath: "/tmp", isDirectory: true), FileManager.default.temporaryDirectory]
                .map { $0.resolvingSymlinksInPath().standardizedFileURL }
            var isDirectory: ObjCBool = false
            // Fail closed: a typo in the fixture path must never launch the real library.
            precondition(path.hasPrefix("/") && temporaryRoots.contains { root.path.hasPrefix($0.path + "/") }
                         && FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                         "OPENFILES_UI_SMOKE_ROOT must be an existing folder beneath /tmp or the system temporary directory.")
            let storage = root.appendingPathComponent("app-state", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            precondition(storage.path.hasPrefix(root.path + "/"), "The UI smoke app-state folder must stay inside its fixture.")
            smokeRoot = root
            let fixtureModel = AppModel(directory: storage)
            fixtureModel.currentFolder = root
            model = fixtureModel
        } else {
            smokeRoot = nil
            model = AppModel()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if smokeRoot != nil {
            NSApp.setActivationPolicy(.regular)
            Task { await showSmokeFixture() }
            return
        }
        NSApp.setActivationPolicy(.accessory)
        searchPanel = SearchPanelController(model: model)
        searchPanel?.activeWorkspaceChanged = { [weak self] in self?.model.activeWorkspace = $0 }
        // Wait until SwiftUI finishes launching its menu-bar scene before taking key focus.
        Task { await model.start(); model.section = .home; model.showWorkspace?() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let smokeWindow { smokeWindow.makeKeyAndOrderFront(nil); return false }
        searchPanel?.show(); return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { smokeRoot != nil }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if smokeRoot != nil { return .terminateNow }
        Task {
            do { await model.finishIndexingBeforeQuit(); _ = try await model.vault.lock(); await self.searchPanel?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
            catch {
                let alert = NSAlert(); alert.messageText = "The vault is still in use"; alert.informativeText = "Close files open from the vault and try quitting again. \(error.localizedDescription)"; alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    /// Screenshot fixture loading deliberately bypasses start(), discovery, watchers, and global search.
    private func showSmokeFixture() async {
        do {
            model.state = try await model.library.load()
            await model.packs.load()
            await model.protection.load()
            model.packs.selectedID = model.packs.packs.first?.id
            model.indexSettings = model.state.indexSettings ?? model.indexSettings
            model.indexSettings.paused = true
            model.indexScopes = model.state.roots
            model.syncStatus = "UI smoke fixture · background discovery is off"
            model.status = "Local fixture · no background indexing"
        } catch {
            model.error = "Could not load UI smoke fixture: \(error.localizedDescription)"
        }
        switch ProcessInfo.processInfo.environment["OPENFILES_UI_SMOKE_SECTION"] ?? Bundle.main.object(forInfoDictionaryKey: "OpenFilesUISmokeSection") as? String ?? "home" {
        case "photos":
            model.section = .photos
            if let fixture = smokeRoot?.appendingPathComponent("Demo.photoslibrary"), FileManager.default.fileExists(atPath: fixture.path) {
                model.photoLibrary.inspect(fixture)
            }
        case "packs": model.section = .packs
        case "protection": model.section = .protection
        case "history": model.section = .history
        default: model.section = .home
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "OpenFiles · UI smoke fixture"
        window.minSize = NSSize(width: 980, height: 680)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: ContentView(cloudModel: CloudBrowserModel()).environmentObject(model))
        model.showWorkspace = { [weak window] in window?.makeKeyAndOrderFront(nil) }
        model.newWorkspace = model.showWorkspace
        smokeWindow = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@main
@MainActor
struct OpenFilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private var model: AppModel { delegate.model }
    var body: some Scene {
        MenuBarExtra("OpenFiles", systemImage: "folder.badge.gearshape") {
            MenuContents().environmentObject(model)
        }
        .commands { WorkspaceCommands(owner: model) }
    }
}

struct WorkspaceCommands: Commands {
    @ObservedObject var owner: AppModel
    private var model: AppModel { owner.activeWorkspace ?? owner }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { model.newWorkspace?() }.keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Version History") {
            Button("Show selected file’s history") {
                if let item = model.selectedItem { model.showVersionPanel(for: item.url) }
            }.keyboardShortcut("h", modifiers: [.command, .option]).disabled(model.selectedItem == nil || model.selectedItem?.sensitive == true)
            if let url = model.editingURL {
                Button("Versions for \(url.lastPathComponent)") { model.showVersionPanel(for: url) }
                Button("Save a version of \(url.lastPathComponent)") { model.showVersionPanel(for: url) }.disabled(model.busy)
            }
            Divider()
            Button("All version history") { model.section = .history; model.showWorkspace?() }
            Button("Save file version…") { model.chooseCommit() }.disabled(model.busy)
            Button("Save folder version…") { model.chooseCommit(project: true) }.disabled(model.busy)
            Button("Automatic versions…") { model.section = .protection; model.showWorkspace?() }
        }
        CommandGroup(after: .newItem) {
            Button("Home") { model.section = .home; model.showWorkspace?() }
            Button("Prepare documents…") { model.section = .packs; model.showWorkspace?() }
            Button("Search files…") { model.showSearch?() }.keyboardShortcut(.space, modifiers: [.command, .shift])
            Button("Browse files…") { model.section = .files; model.showWorkspace?() }
            Button("Clean up files…") { model.section = .cleanup; model.showWorkspace?() }

            Button("Open location…") { model.chooseFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Go to folder…") { model.requestGo() }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("New folder…") { model.showingNewFolder = true }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.section == .cloud)
            Button("Parent folder") { model.up() }.keyboardShortcut(.upArrow, modifiers: .command).disabled(model.section == .cloud)
            Button("Back") { model.back() }.keyboardShortcut("[", modifiers: .command).disabled(model.section == .cloud)
            Button("Forward") { model.forward() }.keyboardShortcut("]", modifiers: .command).disabled(model.section == .cloud)
            Button("Show hidden files") { model.showHidden.toggle() }.keyboardShortcut(".", modifiers: [.command, .shift]).disabled(model.section == .cloud)
            Button("Save file version…") { model.chooseCommit() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Save folder version…") { model.chooseCommit(project: true) }
        }
    }
}

struct MenuContents: View {
    @EnvironmentObject var owner: AppModel
    private var model: AppModel { owner.activeWorkspace ?? owner }
    var body: some View {
        Button("Home") { model.section = .home; show() }
        Button("Prepare documents…") { model.section = .packs; show() }
        Button("Search files…   ⌘⇧Space") { model.showSearch?() }
        Button("Browse files…") { model.section = .files; show() }
        Button("Clean up files…") { model.section = .cleanup; show() }
        Button("New Window") { model.newWorkspace?() }.keyboardShortcut("n", modifiers: .command)
        Divider()
        if let url = model.editingURL {
            Text(url.lastPathComponent)
            Button("Versions for \(url.lastPathComponent)") { model.showVersionPanel(for: url) }
            Button("Review and save version") { model.showVersionPanel(for: url) }.disabled(model.busy)
            Divider()
        }
        Button("Save file version…") { show(); model.chooseCommit() }.disabled(model.busy)
        Button("Save folder version…") { show(); model.chooseCommit(project: true) }.disabled(model.busy)
        Button("Automatic versions…") { model.section = .protection; show() }
        Divider()
        Button("Indexing activity…") { show(); model.showingIndexing = true }
        Button(model.indexSettings.paused ? "Resume indexing" : "Pause indexing") { model.setIndexPaused(!model.indexSettings.paused) }
        Divider()
        if model.vaultState.mounted { Button("Lock private vault") { model.lockVault() }.disabled(model.busy) }
        Button("Quit OpenFiles") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
    private func show() { model.showWorkspace?() }
}
