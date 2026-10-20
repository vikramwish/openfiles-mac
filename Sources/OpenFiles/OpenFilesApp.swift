import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            do { _ = try await model.vault.lock(); sender.reply(toApplicationShouldTerminate: true) }
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
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("OpenFiles", id: "main") {
            ContentView().environmentObject(model)
                .frame(minWidth: 980, minHeight: 680)
                .task { delegate.model = model; await model.start() }
        }
        .defaultSize(width: 1260, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
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
        MenuBarExtra("OpenFiles", systemImage: "folder.badge.gearshape") {
            MenuContents().environmentObject(model)
        }
    }
}

struct MenuContents: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open OpenFiles") { show() }
        Divider()
        Button("Commit file…") { show(); model.chooseCommit() }.disabled(model.busy)
        Button("Commit project folder…") { show(); model.chooseCommit(project: true) }.disabled(model.busy)
        Divider()
        if model.vaultState.mounted { Button("Lock private vault") { model.lockVault() }.disabled(model.busy) }
        Button("Quit OpenFiles") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
    private func show() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
}
