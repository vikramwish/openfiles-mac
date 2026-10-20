import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model = AppModel()
    private var searchPanel: SearchPanelController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        searchPanel = SearchPanelController(model: model)
        searchPanel?.activeWorkspaceChanged = { [weak self] in self?.model.activeWorkspace = $0 }
        // Wait until SwiftUI finishes launching its menu-bar scene before taking key focus.
        Task { await model.start(); searchPanel?.show() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        searchPanel?.show(); return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            do { await model.finishIndexingBeforeQuit(); _ = try await model.vault.lock(); self.searchPanel?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
            catch {
                let alert = NSAlert(); alert.messageText = "The vault is still in use"; alert.informativeText = "Close files open from the vault and try quitting again. \(error.localizedDescription)"; alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
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
                Button("Review & commit \(url.lastPathComponent)") { model.showVersionPanel(for: url) }.disabled(model.busy)
            }
            Divider()
            Button("All version history") { model.section = .history; model.showWorkspace?() }
            Button("Commit file…") { model.chooseCommit() }.disabled(model.busy)
            Button("Commit project folder…") { model.chooseCommit(project: true) }.disabled(model.busy)
        }
        CommandGroup(after: .newItem) {
            Button("Search files…") { model.showSearch?() }.keyboardShortcut(.space, modifiers: [.command, .shift])
            Button("Browse files…") { model.showWorkspace?() }

            Button("Open location…") { model.chooseFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Go to folder…") { model.requestGo() }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("New folder…") { model.showingNewFolder = true }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Parent folder") { model.up() }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("Back") { model.back() }.keyboardShortcut("[", modifiers: .command)
            Button("Forward") { model.forward() }.keyboardShortcut("]", modifiers: .command)
            Button("Show hidden files") { model.showHidden.toggle() }.keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Commit file…") { model.chooseCommit() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Commit project folder…") { model.chooseCommit(project: true) }
        }
    }
}

struct MenuContents: View {
    @EnvironmentObject var owner: AppModel
    private var model: AppModel { owner.activeWorkspace ?? owner }
    var body: some View {
        Button("Search files…   ⌘⇧Space") { model.showSearch?() }
        Button("Browse files…") { model.section = .files; show() }
        Button("New Window") { model.newWorkspace?() }.keyboardShortcut("n", modifiers: .command)
        Divider()
        if let url = model.editingURL {
            Text(url.lastPathComponent)
            Button("Versions for \(url.lastPathComponent)") { model.showVersionPanel(for: url) }
            Button("Review & commit changes") { model.showVersionPanel(for: url) }.disabled(model.busy)
            Divider()
        }
        Button("Commit file…") { show(); model.chooseCommit() }.disabled(model.busy)
        Button("Commit project folder…") { show(); model.chooseCommit(project: true) }.disabled(model.busy)
        Divider()
        Button("Indexing activity…") { show(); model.showingIndexing = true }
        Button(model.indexSettings.paused ? "Resume indexing" : "Pause indexing") { model.setIndexPaused(!model.indexSettings.paused) }
        Divider()
        if model.vaultState.mounted { Button("Lock private vault") { model.lockVault() }.disabled(model.busy) }
        Button("Quit OpenFiles") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
    private func show() { model.showWorkspace?() }
}
