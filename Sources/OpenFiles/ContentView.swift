import SwiftUI
import OpenFilesCore
import OpenFilesCloud

// Type-context alias keeps the property wrapper unambiguous on newer SDKs.
private typealias ViewState<Value> = SwiftUI.State<Value>

private let line = Color.primary.opacity(0.09)
private let surface = Color(nsColor: .controlBackgroundColor)

@MainActor
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var columns: NavigationSplitViewVisibility = .all
    @ViewState private var showsInspector = false
    @ViewState private var focusSearchRequest = 0
    @ObservedObject var cloudModel: CloudBrowserModel
    @ViewState private var focusedHistory: URL?
    @StateObject private var organizationSession = OrganizationSession()
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if model.section == .files {
                        files
                    } else if model.section == .cloud {
                        CloudBrowserView(model: cloudModel)
                    } else {
                        Group {
                            switch model.section {
                            case .home: HomeView(collections: model.collections, cloud: cloudModel)
                            case .collections: CollectionsView(collections: model.collections)
                            case .organize: OrganizationView(session: organizationSession, automaticallyAnalyze: true)
                            case .photos: PhotoLibraryView(model: model.photoLibrary)
                            case .cleanup: CleanupView(model: model.cleanup)
                            case .packs: DocumentPacksView(packs: model.packs)
                            case .protection: ProtectionView(model: model.protection, openHistory: { focusedHistory = $0; model.section = .history })
                            case .history:
                                if let url = focusedHistory {
                                    VStack(spacing: 0) {
                                        HStack {
                                            Button("All saved versions") { focusedHistory = nil }
                                            Spacer()
                                            Text(url.lastPathComponent).font(.headline)
                                        }.padding(16)
                                        VersionHistoryView(url: url).id(url)
                                    }
                                } else { history }
                            case .vault: VaultView()
                            case .files, .cloud: EmptyView()
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(alignment: .top, spacing: 24) {
                    VolumeStorageView(url: model.section == .files ? model.currentFolder : FileManager.default.homeDirectoryForCurrentUser)
                    Spacer()
                    if cloudModel.connected {
                        StorageUsageView(title: cloudModel.provider == .googleDrive ? "Google account storage" : "OneDrive storage", usage: cloudModel.storageUsage, loading: cloudModel.loadingStorage, error: cloudModel.storageError)
                        Button { cloudModel.refreshStorageUsage() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Refresh cloud storage usage").accessibilityLabel("Refresh cloud storage usage")
                    }
                }.padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
                HStack(spacing: 8) {
                    if model.section == .cloud {
                        if cloudModel.transferBusy { ProgressView().controlSize(.mini) }
                        Text(cloudModel.status).lineLimit(1).help(cloudModel.status)
                    } else {
                        if model.busy { ProgressView().controlSize(.mini) }
                        Text(model.status).lineLimit(1).help(model.status)
                    }

                    Spacer(minLength: 16)
                    if model.section != .cloud {
                        Button { model.showingIndexing = true } label: {
                            Label(model.indexing ? "\(model.indexProgress.processed) of \(model.indexProgress.discovered) indexed" : "Indexing Activity", systemImage: model.indexSettings.paused ? "pause.circle" : "waveform.path")
                        }.buttonStyle(.borderless).help("View indexing progress and controls")
                    } else {
                        Text("CLOUD STORAGE").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
            }.background(Color(nsColor: .textBackgroundColor))
        }
        .task { await model.collections.load() }
        .background(CollectionErrorPresenter(collections: model.collections))
        .background(NativeWindowChrome(model: model, toggleSidebar: {
            columns = columns == .detailOnly ? .all : .detailOnly
        }, showsInspector: $showsInspector, focusSearchRequest: focusSearchRequest).frame(width: 0, height: 0))
        .background {
            Button("Find") { focusSearchRequest += 1 }.keyboardShortcut("f").hidden()
        }
        .onChange(of: model.versionFocus) { showsInspector = true }
        .alert("OpenFiles", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.showingIndexing) { IndexingView() }
        .sheet(isPresented: $model.showingGo) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Go to folder").font(.title2.weight(.semibold))
                TextField("/Users/you/Documents", text: $model.pathInput).textFieldStyle(.roundedBorder).onSubmit { model.goToPath() }
                HStack { Spacer(); Button("Cancel") { model.showingGo = false }.keyboardShortcut(.cancelAction); Button("Go") { model.goToPath() }.keyboardShortcut(.defaultAction) }
            }.padding(26).frame(width: 480)
        }
        .sheet(isPresented: $model.showingNewFolder) {
            VStack(alignment: .leading, spacing: 18) {
                Text("New folder").font(.title2.weight(.semibold))
                TextField("Folder name", text: $model.newFolderName).textFieldStyle(.roundedBorder).onSubmit { model.createFolder() }
                HStack { Spacer(); Button("Cancel") { model.showingNewFolder = false }.keyboardShortcut(.cancelAction); Button("Create") { model.createFolder() }.keyboardShortcut(.defaultAction).disabled(model.newFolderName.isEmpty) }
            }.padding(26).frame(width: 420)
        }
        .sheet(item: $model.previewItem) { item in
            VStack(spacing: 0) {
                HStack { Text(item.name).font(.headline); Spacer(); Button("Open") { model.open(item) }; Button("Done") { model.previewItem = nil }.keyboardShortcut(.cancelAction) }.padding(18)
                Divider()
                FilePreview(url: item.url).frame(minWidth: 640, minHeight: 460)
            }
        }
        .sheet(item: $model.renameItem) { item in RenameSuggestionView(item: item).environmentObject(model) }
        .sheet(item: $model.batchRenameRequest) { request in BatchRenameView(request: request).environmentObject(model) }
    }
    private var sidebarSelection: Binding<String?> {
        Binding(get: {
            if model.section == .cloud { return "provider:" + cloudModel.provider.rawValue }
            if model.section == .files {
                let current = model.currentFolder.standardizedFileURL
                if model.locations.contains(where: { $0.url.standardizedFileURL == current }) ||
                    model.volumes.contains(where: { $0.standardizedFileURL == current }) || current == cloudFolder.standardizedFileURL {
                    return current.absoluteString
                }
            }
            return model.section.rawValue
        }, set: { value in
            guard let value else { return }
if value.hasPrefix("provider:"), let provider = CloudProvider(rawValue: String(value.dropFirst(9))) {
                cloudModel.selectProvider(provider); model.section = .cloud
            }
            else if let section = AppModel.Section(rawValue: value) { model.query = ""; model.section = section }
            else if let url = URL(string: value) { model.navigate(to: url) }
        })
    }
    private var cloudFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true) }
    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                Label("Home", systemImage: "house").tag(AppModel.Section.home.rawValue)
                Label("Collections", systemImage: "rectangle.stack").tag(AppModel.Section.collections.rawValue)
                Label("Prepare documents", systemImage: "checklist").tag(AppModel.Section.packs.rawValue)
                Label("Browse files", systemImage: "folder").tag(AppModel.Section.files.rawValue)
                Label("Cloud storage", systemImage: "cloud").tag(AppModel.Section.cloud.rawValue)
            }
            Section("Tools") {
                ForEach([AppModel.Section.protection, .history, .organize, .cleanup, .photos, .vault]) { section in
                    Label(section.rawValue, systemImage: section.icon).tag(section.rawValue)
                }
            }
            Section("Favorites") {
                ForEach(model.locations, id: \.url) { location in
                    Label(location.name, systemImage: location.icon).tag(location.url.absoluteString)
                        .help(location.url.path)
                }
            }
            Section("Cloud storage") {
                ForEach(CloudProvider.allCases) { provider in
                    Label(provider.displayName, systemImage: "cloud").tag("provider:" + provider.rawValue)
                }
            }
            if !model.volumes.isEmpty || FileManager.default.fileExists(atPath: cloudFolder.path) {
            Section("Locations") {
                ForEach(model.volumes, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: "externaldrive").tag(url.absoluteString).help(url.path)
                }
                let cloud = cloudFolder
                if FileManager.default.fileExists(atPath: cloud.path) {
                    Label("iCloud Drive", systemImage: "icloud").tag(cloud.absoluteString)
                }
            }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { model.showingIndexing = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.indexSettings.paused ? "pause.circle" : "checkmark.shield")
                    Text(model.indexSettings.paused ? "Updates paused" : model.indexing ? "Getting files ready…" : "File activity").lineLimit(1)
                    Spacer(minLength: 0)
                }.font(.caption).foregroundStyle(.secondary).padding(14)
            }.buttonStyle(.plain).help("Manage folder access and background updates")
        }
    }
    private var files: some View {
        HStack(spacing: 0) {
            BrowserView().frame(minWidth: 420)
            if showsInspector, let item = model.selectedItem {
                Divider()
                if item.sensitive {
                    VStack(spacing: 12) {
                        Label("Version history unavailable", systemImage: "lock.shield")
                        Text("Potentially sensitive files are excluded from history. Use the private vault.").font(.caption).foregroundStyle(.secondary)
                    }.padding(20).frame(width: 280)
                } else {
                    VStack(spacing: 0) {
                        VersionHistoryView(url: item.url).id(item.url)
                        Divider()
                        RelatedFilesView(url: item.url).id(item.url)
                    }.frame(width: 340)
                }
            }
        }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 22) {
            InfoCard(symbol: "clock.arrow.circlepath", title: "Go back to an earlier version", text: "Find an earlier copy of your work and restore it. OpenFiles saves a recovery copy before replacing the current file.")
            if model.state.versions.isEmpty {
                EmptyPanel(symbol: "clock.badge.checkmark", title: "Keep a copy you can come back to", detail: "Choose a file or folder to save a version. You can also turn on Automatic versions for important work.")
                HStack { Button("Save file version…") { model.chooseCommit() }; Button("Save folder version…") { model.chooseCommit(project: true) } }.buttonStyle(.bordered)
            } else {
                List(model.state.versions) { version in
                    HStack(spacing: 16) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) { Text(version.message).font(.body.weight(.medium)); Text(version.name).font(.callout).foregroundStyle(.secondary) }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) { Text(version.created, style: .date); Text(version.created, style: .time) }.font(.callout).foregroundStyle(.secondary)
                        Menu("Restore") {
                            Button("Restore version") { model.restoreSavedVersion(version) }
                            Button("Export copy…") { model.export(version) }
                        }
                    }.padding(.vertical, 12)
                }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 9))
            }
            Text("Open a file from OpenFiles to keep a floating version panel beside its editor. Save in the editor before saving a version.").font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(30).disabled(model.busy)
    }
}

private struct InfoCard: View {
    var symbol: String; var title: String; var text: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title).foregroundStyle(.tint).frame(width: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                Text(text).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct EmptyPanel: View {
    var symbol: String; var title: String; var detail: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct VaultView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var password = ""
    @ViewState private var confirmation = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            InfoCard(symbol: "lock.shield", title: "Private means encrypted", text: "Keep private files in a locked, encrypted space. They stay out of search and version history. Keep your password safe: it can’t be reset.")
            VStack(spacing: 20) {
                Image(systemName: model.vaultState.mounted ? "lock.open" : "lock").font(.system(size: 38, weight: .ultraLight)).padding(.top, 12)
                Text(model.vaultState.mounted ? "Your vault is unlocked" : model.vaultState.exists ? "Unlock your private vault" : "Create your private vault").font(.title2.weight(.semibold))
                if model.vaultState.mounted {
                    Text("Files are accessible to this Mac while the vault is unlocked.").font(.body).foregroundStyle(.secondary)
                    HStack { Button("Browse vault") { model.openVault() }; Button("Copy a file into vault…") { model.importVault() }; Button("Lock vault") { model.lockVault() }.buttonStyle(.borderedProminent) }.buttonStyle(.bordered).controlSize(.large)
                } else {
                    SecureField(model.vaultState.exists ? "Vault password" : "Password (at least 12 characters)", text: $password).textContentType(.password).textFieldStyle(.roundedBorder).frame(width: 320)
                    if !model.vaultState.exists { SecureField("Confirm password", text: $confirmation).textFieldStyle(.roundedBorder).frame(width: 320) }
                    Button(model.vaultState.exists ? "Unlock vault" : "Create encrypted vault") {
                        model.vaultAction(password: password); password = ""; confirmation = ""
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(password.isEmpty || (!model.vaultState.exists && (password.count < 12 || password != confirmation)))
                }
                if model.busy { ProgressView("Working with encrypted storage…").controlSize(.small) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30).background(surface, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(line))
            Label("Adding a file creates a private copy. The original stays in its current folder until you remove it.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).lineSpacing(4)
        }.padding(30).disabled(model.busy)
    }
}
