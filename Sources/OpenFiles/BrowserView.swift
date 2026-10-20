import SwiftUI
import AppKit
import QuickLookUI
import OpenFilesCore

struct BrowserToolbar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    Button { model.back() } label: { Image(systemName: "chevron.left") }.disabled(!model.canGoBack).help("Back").accessibilityLabel("Back")
                    Button { model.forward() } label: { Image(systemName: "chevron.right") }.disabled(!model.canGoForward).help("Forward").accessibilityLabel("Forward")
                    Button { model.up() } label: { Image(systemName: "arrow.up") }.disabled(!model.canGoUp).help("Parent folder").accessibilityLabel("Parent folder")
                }.buttonStyle(.borderless)
                Text(model.query.isEmpty ? (model.currentFolder.path == "/" ? "This Mac" : model.currentFolder.lastPathComponent) : "Search results").font(.system(size: 18, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { model.showingNewFolder = true } label: { Image(systemName: "folder.badge.plus") }.help("New folder").accessibilityLabel("New folder")
                Menu {
                    Button("Go to folder…") { model.requestGo() }
                    Button("Open location…") { model.chooseFolder() }
                    Toggle("Show hidden files", isOn: $model.showHidden)
                    Button("Refresh") { model.refresh() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel("Folder options")
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search this Mac", text: $model.query).textFieldStyle(.plain).accessibilityLabel("Search this Mac")
                    if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
                }.font(.system(size: 12)).padding(9).frame(width: 280).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.borderless)
            if model.query.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        Button("This Mac") { model.navigate(to: URL(fileURLWithPath: "/", isDirectory: true)) }
                        ForEach(ancestors, id: \.self) { url in
                            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                            Button(url.lastPathComponent) { model.navigate(to: url) }
                        }
                    }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    Text("Search:").foregroundStyle(.secondary)
                    Button("This Mac") { model.searchThisFolder = false }.buttonStyle(.bordered).tint(model.searchThisFolder ? .secondary : .primary)
                    Button(model.currentFolder.lastPathComponent) { model.searchThisFolder = true }.buttonStyle(.bordered).tint(model.searchThisFolder ? .primary : .secondary)
                    Spacer()
                    if model.searchingSystem { ProgressView().controlSize(.mini); Text("Searching Spotlight…").foregroundStyle(.secondary) }
                }.font(.system(size: 10)).controlSize(.small)
            }
        }.padding(.horizontal, 24).padding(.top, 38).padding(.bottom, 16)
    }
    private var ancestors: [URL] {
        var folder = model.currentFolder; var result: [URL] = []
        while folder.path != "/" { result.insert(folder, at: 0); folder.deleteLastPathComponent() }
        return result
    }
}

struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var listFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Name"); Spacer()
                Text(model.query.isEmpty ? "Size" : "Location").frame(width: model.query.isEmpty ? 80 : 180, alignment: .leading)
                Text("Kind").frame(width: 85, alignment: .leading)
                Text("Modified").frame(width: 100, alignment: .leading)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 11)
            Divider().opacity(0.5)
            if let error = model.folderError, model.query.isEmpty {
                VStack(spacing: 15) {
                    Image(systemName: "folder.badge.questionmark").font(.system(size: 35, weight: .light))
                    Text("This folder isn’t accessible").font(.headline)
                    Text(error).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("macOS may require folder access or Full Disk Access for protected locations.").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack { Button("Try again") { model.reloadFolder() }; Button("Go Home") { model.navigate(to: FileManager.default.homeDirectoryForCurrentUser) } }.buttonStyle(.bordered)
                }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.loadingFolder && model.query.isEmpty { ProgressView("Opening folder…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if model.browserItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.query.isEmpty ? "folder" : "magnifyingglass").font(.system(size: 35, weight: .ultraLight)).foregroundStyle(.secondary)
                    Text(model.query.isEmpty ? "This folder is empty" : model.searchingSystem ? "Searching this Mac…" : "No matching files").font(.system(size: 17, weight: .medium))
                    Text(model.query.isEmpty ? "Create a folder or choose another location in the sidebar." : "Try a filename or describe the contents. Spotlight results depend on macOS indexing and permissions.").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedURL) {
                    ForEach(model.browserItems) { item in
                        BrowserRow(item: item, showingLocation: !model.query.isEmpty).tag(item.url)
                            .contentShape(Rectangle()).onTapGesture(count: 2) { model.open(item) }
                            .simultaneousGesture(TapGesture().onEnded { model.selectedURL = item.url; listFocused = true })
                            .contextMenu {
                                Button(item.isFolder ? "Open folder" : "Open") { model.open(item) }
                                Button("Quick Look") { model.previewItem = item }
                                if !model.query.isEmpty { Button("Show enclosing folder") { model.open(item, reveal: true) } }
                                Divider()
                                Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.url.path, forType: .string) }
                                Button("Commit version…") { model.prepareCommit(item) }.disabled(item.sensitive)
                            }
                    }
                }.listStyle(.inset).focused($listFocused).onKeyPress(.return) { model.openSelected(); return .handled }.onKeyPress(.space) { model.previewSelected(); return .handled }
            }
            Divider().opacity(0.5)
            HStack {
                Text("\(model.browserItems.count) items")
                if !model.query.isEmpty { Text(model.searchThisFolder ? "· Folder search + semantic matches" : "· This Mac search + semantic matches"); if model.searchResultCount > 1000 { Text("· Showing the first 1,000 Spotlight matches") } }
                Spacer()
                Text("Return to open · Space to preview").foregroundStyle(.tertiary)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 11)
        }
    }
}

private struct BrowserRow: View {
    @EnvironmentObject var model: AppModel
    let item: BrowserItem
    let showingLocation: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 22, height: 22)
            Text(item.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 8)
            if showingLocation {
                Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(width: 180, alignment: .leading)
            } else {
                Text(item.isFolder ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            }
            Text(item.kind).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 85, alignment: .leading)
            Text(item.modified, style: .date).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
        }.padding(.vertical, 5).help(item.url.path)
    }
}

struct FilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { let view = QLPreviewView(frame: .zero, style: .normal)!; view.autostarts = true; return view }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}
