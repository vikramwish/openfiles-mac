import SwiftUI
import AppKit
import QuickLookUI
import OpenFilesCore
import OpenFilesCloud

private typealias BrowserState<Value> = SwiftUI.State<Value>

struct BrowserToolbar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            if model.query.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Image(systemName: "internaldrive").foregroundStyle(.secondary)
                        Button("This Mac") { model.navigate(to: URL(fileURLWithPath: "/", isDirectory: true)) }
                        ForEach(ancestors, id: \.self) { url in
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            Button(url.lastPathComponent) { model.navigate(to: url) }.help(url.path)
                        }
                    }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Search:").foregroundStyle(.secondary)
                Picker("Search scope", selection: $model.searchThisFolder) {
                    Text("This Mac").tag(false)
                    Text(model.currentFolder.lastPathComponent).tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                Spacer()
                if model.searchingSystem { ProgressView().controlSize(.small).help("Searching Spotlight") }
            }
        }.padding(.horizontal, 16).padding(.vertical, 9).background(.bar)
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
    @BrowserState private var showsPreview = true
    @BrowserState private var sortOrder: [KeyPathComparator<BrowserItem>] = []
    private var sortedItems: [BrowserItem] { sortOrder.isEmpty ? model.browserItems : model.browserItems.sorted(using: sortOrder) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                BrowserToolbar()
                Toggle(isOn: $showsPreview) { Label("Preview", systemImage: "rectangle.trailinghalf.inset.filled") }
                    .toggleStyle(.button).help("Show or hide the inline file preview").padding(.trailing, 12)
            }.background(.bar)
            if let selected = model.selectedItem {
                HStack {
                    Spacer()
                    AddToCollectionMenu(collections: model.collections, urls: [selected.url])
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
            Divider()
            GeometryReader { geometry in
                if showsPreview {
                    if geometry.size.width >= 680 {
                        HSplitView {
                            fileList.frame(minWidth: 340)
                            InlineBrowserPreview(item: model.selectedItem).frame(minWidth: 260, idealWidth: 330, maxWidth: 480)
                        }
                    } else {
                        VSplitView {
                            fileList.frame(minHeight: 180)
                            InlineBrowserPreview(item: model.selectedItem).frame(minHeight: 180, idealHeight: 260)
                        }
                    }
                } else { fileList }
            }
            Divider()
            HStack {
                VolumeStorageView(url: model.currentFolder)
                Spacer()
                if let item = model.selectedItem, !item.isFolder, !item.isPackage {
                    Button("Suggest Filename…") { model.renameItem = item }.disabled(item.sensitive)
                }
            }.font(.caption).padding(10)
        }
    }
    @ViewBuilder private var fileList: some View {
        if let error = model.folderError, model.query.isEmpty {
            VStack(spacing: 15) {
                Image(systemName: "folder.badge.questionmark").font(.system(size: 35, weight: .light))
                Text("This folder isn’t accessible").font(.headline)
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("macOS may require folder access or Full Disk Access for protected locations.").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack { Button("Try again") { model.reloadFolder() }; Button("Open Home folder") { model.navigate(to: FileManager.default.homeDirectoryForCurrentUser) } }.buttonStyle(.bordered)
            }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.loadingFolder && model.query.isEmpty { ProgressView("Opening folder…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        else if model.browserItems.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: model.query.isEmpty ? "folder" : "magnifyingglass").font(.system(size: 35, weight: .ultraLight)).foregroundStyle(.secondary)
                Text(model.query.isEmpty ? "This folder is empty" : model.searchingSystem ? "Searching this Mac…" : "No matching files").font(.system(size: 17, weight: .medium))
                Text(model.query.isEmpty ? "Create a folder or choose another location in the sidebar." : "Try a few different words, or choose another folder.").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
            }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(sortedItems, selection: $model.selectedURL, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { item in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 20, height: 20)
                        Text(item.name).lineLimit(1)
                    }.help(item.url.path)
                }.width(min: 160, ideal: 320)
                TableColumn("Date Modified", value: \.modified) { item in
                    Text(item.modified, format: .dateTime.month(.abbreviated).day().year()).foregroundStyle(.secondary)
                }.width(min: 100, ideal: 140)
                TableColumn(model.query.isEmpty ? "Size" : "Location") { item in
                    if model.query.isEmpty {
                        Text(item.isFolder ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).foregroundStyle(.secondary)
                    } else {
                        Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(item.url.path)
                    }
                }.width(min: 70, ideal: model.query.isEmpty ? 90 : 180)
                TableColumn("Kind", value: \.kind) { item in Text(item.kind).foregroundStyle(.secondary) }.width(min: 80, ideal: 100)
                TableColumn("Stored in") { item in FileLocationTag(location: .local(item.url)) }.width(min: 100, ideal: 125)
            }
            .contextMenu(forSelectionType: URL.self) { selection in
                if let item = model.browserItems.first(where: { selection.contains($0.url) }) {
                    Button(item.isFolder ? "Open Folder" : "Open") { model.open(item) }
                    Button("Quick Look") { model.previewItem = item }
                    if !model.query.isEmpty { Button("Show Enclosing Folder") { model.open(item, reveal: true) } }
                    Divider()
                    Menu("Add to collection") {
                        ForEach(model.collections.collections) { collection in
                            Button(collection.title) { model.collections.add([item.url], to: collection.id) }
                        }
                    }.disabled(model.collections.busy || model.collections.collections.isEmpty)
                    Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.url.path, forType: .string) }
                    Button("Suggest Filename…") { model.renameItem = item }.disabled(item.isFolder || item.isPackage || item.sensitive)
                    Button("Save version…") { model.prepareCommit(item) }.disabled(item.sensitive)
                }
            } primaryAction: { selection in
                if let item = model.browserItems.first(where: { selection.contains($0.url) }) { model.open(item) }
            }
            .focused($listFocused)
            .onKeyPress(.return) { model.openSelected(); return .handled }
            .onKeyPress(.space) { model.previewSelected(); return .handled }

        }
    }
}

struct InlineBrowserPreview: View {
    let item: BrowserItem?
    var body: some View {
        VStack(spacing: 0) {
            if let item {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.headline).lineLimit(2).textSelection(.enabled)
                        Text(item.isFolder ? "Folder" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }.padding(14)
                Divider()
                if item.isFolder && !item.isPackage {
                    ContentUnavailableView("Folder selected", systemImage: "folder", description: Text("Open the folder to select a file to preview."))
                } else {
                    FilePreview(url: item.url).id(item.url).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("Select a file to preview", systemImage: "doc.text.magnifyingglass", description: Text("Images, PDFs, documents, and other Quick Look formats appear here."))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }
}

struct FilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { let view = QLPreviewView(frame: .zero, style: .normal)!; view.autostarts = true; return view }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}
