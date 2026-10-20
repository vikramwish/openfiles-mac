import SwiftUI
import AppKit
import Carbon
import OpenFilesCore

struct SearchResult: Identifiable {
    var id: URL { item.url }
    let item: BrowserItem
    let score: Double
    let reason: String
}

@MainActor
final class SearchStore: ObservableObject {
    @Published var text = "" { didSet { if text != oldValue { search() } } }
    @Published var results: [SearchResult] = []
    @Published var selected = 0
    @Published var searching = false
    @Published var focusID = UUID()
    @Published var shortcutAvailable = true
    private let model: AppModel
    private let spotlight = SystemSearch()
    private var task: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var generation = UUID()
    private var local: [SearchResult] = []
    private var system: [SearchResult] = []
    private var localWorking = false
    private var systemWorking = false
    var resize: ((Bool) -> Void)?
    var dismiss: (() -> Void)?
    var browse: (() -> Void)?
    var preview: (() -> Void)?
    var selectedItem: BrowserItem? { results.indices.contains(selected) ? results[selected].item : nil }
    var hasQuery: Bool { !FileSearchQuery(text).terms.isEmpty }
    init(model: AppModel) {
        self.model = model
        spotlight.onUpdate = { [weak self] urls, gathering, _ in
            guard let self else { return }
            self.systemWorking = gathering
            let token = self.generation, plan = FileSearchQuery(self.text)
            self.updateTask?.cancel()
            self.updateTask = Task {
                let data = await self.model.library.directory
                let visible = urls.filter { !FileRules.contains(data, $0.resolvingSymlinksInPath()) }
                let items = await self.model.browser.items(at: Array(visible.prefix(120)))
                guard self.generation == token, !Task.isCancelled else { return }
                self.system = items.map { item in
                    let nameScore = plan.score(name: item.name, content: "")
                    return SearchResult(item: item, score: nameScore ?? 2, reason: nameScore != nil ? "Filename matches" : "Spotlight content match")
                }
                self.merge()
            }
        }
    }
    func search() {
        task?.cancel(); updateTask?.cancel(); spotlight.stop(); generation = UUID()
        results = []; local = []; system = []; selected = 0
        localWorking = false; systemWorking = false
        resize?(hasQuery)
        guard hasQuery else { searching = false; return }
        searching = true; localWorking = true; systemWorking = true
        let token = generation, input = text
        task = Task {
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard !Task.isCancelled else { return }
            spotlight.search(input)
            let matches = await model.library.searchMatches(input)
            let items = await model.browser.items(at: matches.prefix(100).map { $0.file.url })
            guard generation == token, !Task.isCancelled else { return }
            let byURL = Dictionary(items.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
            local = matches.compactMap { match in byURL[match.file.url].map { SearchResult(item: $0, score: match.score, reason: match.reason) } }
            localWorking = false; merge()
            // Spotlight can keep gathering on busy volumes; retain its live updates.
        }
    }
    private func merge() {
        let selectedID = selectedItem?.id
        var byPath: [String: SearchResult] = [:]
        for result in local + system {
            let key = result.item.url.resolvingSymlinksInPath().standardizedFileURL.path
            if result.score > (byPath[key]?.score ?? -.infinity) { byPath[key] = result }
        }
        results = Array(byPath.values.sorted { $0.score == $1.score ? $0.item.url.path < $1.item.url.path : $0.score > $1.score }.prefix(100))
        selected = selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        searching = localWorking || systemWorking
    }
    func move(_ delta: Int) { guard !results.isEmpty else { return }; selected = min(max(selected + delta, 0), results.count - 1) }
    func openSelected() {
        guard let item = selectedItem else { return }
        dismiss?()
        if item.isFolder { model.navigate(to: item.url); browse?() }
        else { model.open(item) }
    }
    func revealSelected() {
        guard let item = selectedItem else { return }
        model.open(item, reveal: true); dismiss?(); browse?()
    }
    func stop() { task?.cancel(); updateTask?.cancel(); spotlight.stop(); generation = UUID(); searching = false; localWorking = false; systemWorking = false }
    func resume() { focusID = UUID(); if hasQuery { search() } }
}

private final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onDismiss: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    override func resignKey() { super.resignKey(); onDismiss?() }
}

/// RegisterEventHotKey reserves only our chord; no global key logger or Accessibility access.
@MainActor
final class GlobalSearchShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    func register() -> Bool {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalSearchShortcut>.fromOpaque(data).takeUnretainedValue()
            Task { @MainActor in shortcut.action?() }
            return noErr
        }, 1, &type, context, &handler)
        guard status == noErr else { return false }
        let id = EventHotKeyID(signature: OSType(0x4F46494C), id: 1)
        return RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}

@MainActor
final class SearchPanelController {
    let store: SearchStore
    private let panel: SearchPanel
    private let shortcut = GlobalSearchShortcut()
    private let model: AppModel
    private var browserWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var previousApp: NSRunningApplication?
    init(model: AppModel) {
        self.model = model
        store = SearchStore(model: model)
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 740, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "Search OpenFiles"
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: SearchPanelView(store: store))
        host.sizingOptions = []; host.frame = panel.contentRect(forFrameRect: panel.frame); host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.onDismiss = { [weak self] in self?.hide(returnFocus: false) }
        store.dismiss = { [weak self] in self?.hide() }
        store.browse = { [weak self] in self?.showBrowser() }
        store.preview = { [weak self] in self?.showPreview() }
        store.resize = { [weak self] expanded in self?.resize(expanded) }
        shortcut.action = { [weak self] in self?.toggle() }
        store.shortcutAvailable = shortcut.register()
        model.showSearch = { [weak self] in self?.show() }
        model.showWorkspace = { [weak self] in self?.showBrowser() }
    }
    func show() {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let width = min(740, visible.width - 40)
            panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.maxY - visible.height * 0.22 - panel.frame.height, width: width, height: panel.frame.height), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil); store.resume()
    }
    func hide(returnFocus: Bool = true) {
        let wasKey = panel.isKeyWindow
        panel.orderOut(nil); store.stop()
        if returnFocus && wasKey { previousApp?.activate(options: []) }
    }
    func toggle() { if panel.isVisible && panel.isKeyWindow { hide() } else { show() } }
    private func resize(_ expanded: Bool) {
        let top = panel.frame.maxY
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let height: CGFloat = min(expanded ? 540 : 240, visible.height - 40)
        panel.setFrame(NSRect(x: panel.frame.minX, y: max(visible.minY + 20, top - height), width: panel.frame.width, height: height), display: true)
    }
    func showBrowser() {
        hide()
        if browserWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "OpenFiles"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.minSize = NSSize(width: 980, height: 680); window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentView().environmentObject(model))
            window.center(); browserWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); browserWindow?.makeKeyAndOrderFront(nil)
    }
    private func showPreview() {
        guard let item = store.selectedItem else { return }
        // A separate Quick Look window keeps the compact search panel's layout stable.
        hide()
        if previewWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.center(); previewWindow = window
        }
        previewWindow?.title = item.name
        previewWindow?.contentView = NSHostingView(rootView: FilePreview(url: item.url))
        NSApp.activate(ignoringOtherApps: true); previewWindow?.makeKeyAndOrderFront(nil)
    }
    func shutdown() { shortcut.unregister(); store.stop() }
}

private struct SearchPanelView: View {
    @ObservedObject var store: SearchStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) {
                Image(systemName: "magnifyingglass").font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
                SearchInput(text: $store.text, focusID: store.focusID, submit: { store.openSelected() }, move: { store.move($0) }, escape: { store.dismiss?() })
                    .frame(height: 42)
                if store.searching { ProgressView().controlSize(.small).accessibilityLabel("Searching files") }
                else if !store.text.isEmpty {
                    Button { store.text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("Clear search")
                }
                Text("esc").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).padding(5).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.08)))
            }.padding(.horizontal, 24).padding(.vertical, 15)
            Divider().opacity(0.6)
            if store.hasQuery {
                HStack {
                    Text(store.searching ? "SEARCHING YOUR MAC" : "\(store.results.count) RESULTS").tracking(1)
                    Spacer()
                    Text(FileSearchQuery(store.text).text).lineLimit(1)
                }.font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 8)
                if store.results.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: store.searching ? "doc.text.magnifyingglass" : "magnifyingglass").font(.system(size: 27, weight: .light)).foregroundStyle(.tertiary)
                        Text(store.searching ? "Looking for relevant files…" : "No confident matches").font(.system(size: 15, weight: .medium))
                        Text(store.searching ? "Searching Spotlight and the local document index." : "Try a filename, agency, or topic. Results depend on indexing and folder access.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(Array(store.results.enumerated()), id: \.element.id) { index, result in
                                    resultRow(result, index: index).id(result.id)
                                }
                            }.padding(.horizontal, 10).padding(.bottom, 10)
                        }.onChange(of: store.selected) { _, value in
                            if store.results.indices.contains(value) { reader.scrollTo(store.results[value].id) }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your files, a few words away.").font(.system(size: 14, weight: .medium))
                    HStack(spacing: 8) {
                        example("Australian government files")
                        example("Invoices")
                        example("Launch plan")
                    }
                    Text("Search by name or describe the contents.").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 24)
            }
            Divider().opacity(0.6)
            HStack(spacing: 12) {
                Image(systemName: "sparkle"); Text("OpenFiles").fontWeight(.medium)
                if !store.shortcutAvailable { Text("Shortcut unavailable — use menu bar").foregroundStyle(.secondary) }
                Spacer()
                if store.hasQuery { Text("↑↓ select   ↵ open").foregroundStyle(.secondary) }
                Button { store.browse?() } label: { Label("Browse", systemImage: "folder") }.buttonStyle(.borderless).help("Open full file browser")
            }.font(.system(size: 10)).padding(.horizontal, 22).padding(.vertical, 12)
        }
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else { Rectangle().fill(.regularMaterial) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.12)))
    }
    private func example(_ text: String) -> some View {
        Button(text) { store.text = text }.buttonStyle(.plain).font(.system(size: 11)).padding(.horizontal, 11).padding(.vertical, 7)
            .background(Color.primary.opacity(0.045), in: Capsule()).overlay(Capsule().stroke(Color.primary.opacity(0.05)))
    }
    private func resultRow(_ result: SearchResult, index: Int) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: result.item.url.path)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(result.item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(result.item.url.deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 10)
            Text(result.reason).font(.system(size: 9)).foregroundStyle(.secondary)
            Button { store.selected = index; store.preview?() } label: { Image(systemName: "eye") }.buttonStyle(.borderless).help("Quick Look").accessibilityLabel("Preview \(result.item.name)")
            Image(systemName: "return").font(.system(size: 10)).foregroundStyle(index == store.selected ? .secondary : .tertiary)
        }.padding(.horizontal, 14).padding(.vertical, 11)
            .background(index == store.selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle()).onTapGesture(count: 2) { store.selected = index; store.openSelected() }
            .onTapGesture { store.selected = index }
            .accessibilityElement(children: .contain).accessibilityAddTraits(index == store.selected ? .isSelected : [])
            .contextMenu {
                Button("Open") { store.selected = index; store.openSelected() }
                Button("Quick Look") { store.selected = index; store.preview?() }
                Button("Show in browser") { store.selected = index; store.revealSelected() }
            }
    }
}

private struct SearchInput: NSViewRepresentable {
    @Binding var text: String
    let focusID: UUID
    var submit: () -> Void
    var move: (Int) -> Void
    var escape: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 23, weight: .regular); field.placeholderString = "Search your Mac…"
        field.delegate = context.coordinator; field.setAccessibilityLabel("Search your Mac")
        field.lineBreakMode = .byTruncatingTail; field.usesSingleLineMode = true
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusID != focusID {
            context.coordinator.focusID = focusID
            DispatchQueue.main.async { field.window?.makeFirstResponder(field); field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0) }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchInput
        var focusID: UUID?
        init(_ parent: SearchInput) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) { if let field = obj.object as? NSTextField { parent.text = field.stringValue } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch NSStringFromSelector(commandSelector) {
            case "moveDown:": parent.move(1)
            case "moveUp:": parent.move(-1)
            case "insertNewline:": parent.submit()
            case "cancelOperation:": parent.escape()
            default: return false
            }
            return true
        }
    }
}
