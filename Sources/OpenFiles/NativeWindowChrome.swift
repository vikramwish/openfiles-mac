import AppKit
import SwiftUI

/// AppKit owns the window chrome even when the workspace is opened from the menu bar.
struct NativeWindowChrome: NSViewRepresentable {
    @ObservedObject var model: AppModel
    var toggleSidebar: () -> Void
    @Binding var showsInspector: Bool
    var focusSearchRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WindowAnchor {
        let view = WindowAnchor()
        view.attached = { [weak coordinator = context.coordinator] window in coordinator?.install(on: window) }
        return view
    }
    func updateNSView(_ view: WindowAnchor, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refresh()
        DispatchQueue.main.async { context.coordinator.refresh() }
    }
    static func dismantleNSView(_ view: WindowAnchor, coordinator: Coordinator) { coordinator.detach() }
    final class WindowAnchor: NSView {
        var attached: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { attached?(window) } }
    }
    @MainActor final class Coordinator: NSObject, NSToolbarDelegate, NSSearchFieldDelegate, NSToolbarItemValidation {
        var parent: NativeWindowChrome
        weak var window: NSWindow?
        private var items: [String: NSToolbarItem] = [:]
        private var search: NSSearchToolbarItem?
        private var toolbar: NSToolbar?
        private var lastFocusRequest = 0
        private var keyMonitor: Any?
        init(_ parent: NativeWindowChrome) { self.parent = parent }
        func install(on window: NSWindow) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            // SwiftUI tables hosted outside a Window scene do not reliably forward onKeyPress.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, (self.parent.model.section == .files || !self.parent.model.query.isEmpty),
                      self.parent.model.selectedItem != nil,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      !(self.window?.firstResponder is NSTextView),
                      (!(self.window?.firstResponder is NSControl) || self.window?.firstResponder is NSTableView) else { return event }
                switch event.keyCode {
                case 49: self.parent.model.previewSelected(); return nil
                case 36: self.parent.model.openSelected(); return nil
                default: return event
                }
            }
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            let toolbar = NSToolbar(identifier: "OpenFiles.Workspace")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            self.toolbar = toolbar
            window.toolbar = toolbar
            refresh()
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
        func detach() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            ["sidebar", "back", "forward", NSToolbarItem.Identifier.flexibleSpace.rawValue, "more", NSToolbarItem.Identifier.flexibleSpace.rawValue, "search"].map { NSToolbarItem.Identifier($0) }
        }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            if identifier.rawValue == "search" {
                let item = NSSearchToolbarItem(itemIdentifier: identifier)
                item.searchField.placeholderString = "Find anything on this Mac"
                item.searchField.delegate = self
                item.searchField.sendsSearchStringImmediately = true
                item.searchField.sendsWholeSearchString = false
                item.preferredWidthForSearchField = 240
                item.searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
                item.searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
                item.label = "Search"
                search = item
                return item
            }
            let item = NSToolbarItem(itemIdentifier: identifier)
            let specification: (String, String, Selector)
            switch identifier.rawValue {
            case "sidebar": specification = ("Show or Hide Sidebar", "sidebar.left", #selector(sidebar))
            case "back": specification = ("Back", "chevron.left", #selector(back))
            case "forward": specification = ("Forward", "chevron.right", #selector(forward))
            case "newFolder": specification = ("New Folder", "folder.badge.plus", #selector(newFolder))
            case "preview": specification = ("Quick Look", "eye", #selector(preview))
            case "inspector": specification = ("Show or Hide Versions", "sidebar.right", #selector(inspector))
            default: specification = ("More Actions", "ellipsis.circle", #selector(more))
            }
            item.label = specification.0; item.toolTip = specification.0
            item.image = NSImage(systemSymbolName: specification.1, accessibilityDescription: specification.0)
            item.target = self; item.action = specification.2
            items[identifier.rawValue] = item
            return item
        }
        func refresh() {
            if let toolbar, window?.toolbar !== toolbar { window?.toolbar = toolbar }
            toolbar?.isVisible = true
            let model = parent.model
            window?.title = model.section == .files ? (model.query.isEmpty ? (model.currentFolder.path == "/" ? "This Mac" : model.currentFolder.lastPathComponent) : "Search") : model.section == .cloud ? model.section.rawValue : "Workspace"
            window?.representedURL = model.section == .files && model.query.isEmpty ? model.currentFolder : nil
            items["back"]?.isEnabled = model.section == .files && model.canGoBack
            items["forward"]?.isEnabled = model.section == .files && model.canGoForward
            items["newFolder"]?.isEnabled = model.section == .files && model.query.isEmpty
            items["preview"]?.isEnabled = model.section == .files && model.selectedItem != nil
            items["inspector"]?.isEnabled = model.section == .files
            if search?.searchField.stringValue != model.query { search?.searchField.stringValue = model.query }
            if parent.focusSearchRequest != lastFocusRequest {
                lastFocusRequest = parent.focusSearchRequest
                search?.beginSearchInteraction()
            }
        }
        func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
            switch item.itemIdentifier.rawValue {
            case "back": return parent.model.section == .files && parent.model.canGoBack
            case "forward": return parent.model.section == .files && parent.model.canGoForward
            case "newFolder": return parent.model.section == .files && parent.model.query.isEmpty
            case "preview": return parent.model.section == .files && parent.model.selectedItem != nil
            case "inspector": return parent.model.section == .files
            default: return true
            }
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            if parent.model.section != .files && parent.model.section != .photos { parent.model.section = .home }
            parent.model.query = field.stringValue
        }
        @objc private func sidebar() { parent.toggleSidebar() }
        @objc private func back() { parent.model.back() }
        @objc private func forward() { parent.model.forward() }
        @objc private func newFolder() { parent.model.showingNewFolder = true }
        @objc private func preview() { parent.model.previewSelected() }
        @objc private func inspector() { parent.showsInspector.toggle() }
        @objc private func more() {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (title, action) in [("New Folder", #selector(newFolder)), ("Quick Look", #selector(preview)), ("Show or Hide Versions", #selector(inspector)), ("Go to Folder…", #selector(go)), ("Open Location…", #selector(location)), ("Show Hidden Files", #selector(hidden)), ("Refresh", #selector(reload)), ("File Activity…", #selector(indexing))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                if action == #selector(newFolder) { item.isEnabled = parent.model.section == .files && parent.model.query.isEmpty }
                if action == #selector(preview) { item.isEnabled = parent.model.section == .files && parent.model.selectedItem != nil }
                if action == #selector(inspector) { item.isEnabled = parent.model.section == .files }
                if action == #selector(hidden) { item.state = parent.model.showHidden ? .on : .off }
                menu.addItem(item)
            }
            if let event = NSApp.currentEvent, let view = window?.contentView { NSMenu.popUpContextMenu(menu, with: event, for: view) }
        }
        @objc private func go() { parent.model.requestGo() }
        @objc private func location() { parent.model.chooseFolder() }
        @objc private func hidden() { parent.model.showHidden.toggle() }
        @objc private func reload() { parent.model.refresh() }
        @objc private func indexing() { parent.model.showingIndexing = true }
    }
}

