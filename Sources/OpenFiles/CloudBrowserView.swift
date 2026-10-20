import SwiftUI
import OpenFilesCloud

private typealias CloudViewState<Value> = SwiftUI.State<Value>

@MainActor
struct CloudBrowserView: View {
    @ObservedObject var model: CloudBrowserModel
    @CloudViewState private var showingSyncReport = false
    @CloudViewState private var showingSync = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("Storage provider", selection: Binding(get: { model.provider }, set: { model.selectProvider($0) })) {
                    ForEach(CloudProvider.allCases) { provider in Text(provider.displayName).tag(provider) }
                }.pickerStyle(.segmented).frame(width: 330).disabled(model.disconnecting)
                Spacer()
                if model.connected {
                    Label(model.connectedForWriting ? "Connected · Uploads enabled" : "Connected · Read only", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Connection settings") { model.showingRegistration.toggle() }.controlSize(.small)
                }
            }

            Text("Browse cloud files, save local copies, or enable uploads and sync. Pairing a folder authorizes transfers of its filenames and contents, including subfolders. Deletions remain manual; cloud browsing stays separate from local indexing.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if !model.connected || model.showingRegistration { registration }
            if model.connected {
                HStack(alignment: .top, spacing: 24) {
                    StorageUsageView(title: model.provider == .googleDrive ? "Google account storage" : "OneDrive storage", usage: model.storageUsage, loading: model.loadingStorage, error: model.storageError)
                    Spacer()
                    VolumeStorageView(url: FileManager.default.homeDirectoryForCurrentUser)
                }
                if model.connectedForWriting {
                    DisclosureGroup("Uploads and folder sync", isExpanded: $showingSync) { syncControls.padding(.top, 8) }
                        .font(.callout)
                }
            }

            if let error = model.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                    if model.connected { Button("Retry") { model.refresh() }.disabled(model.loading) }
                }.font(.system(size: 12)).padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }

            if model.connected { browser.frame(minHeight: 200, maxHeight: .infinity) }
            else if model.loadingConfiguration { ProgressView("Reading saved connection…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { disconnected }

            VStack(alignment: .leading, spacing: 8) {
                if model.downloading {
                    HStack { ProgressView().controlSize(.small); Text("Downloading \(model.downloadName)…").lineLimit(1); Spacer(); Button("Cancel download") { model.cancelDownload() } }
                }
                if model.uploading {
                    HStack { ProgressView().controlSize(.small); Text("Uploading selected files…"); Spacer(); Button("Cancel upload") { model.cancelUpload() } }
                }
                if model.syncing {
                    HStack { ProgressView().controlSize(.small); Text("Working on the paired folders…"); Spacer(); Button("Cancel sync") { model.cancelSync() } }
                }
                HStack(alignment: .top) {
                    Text(model.status).textSelection(.enabled)
                    Spacer()
                    if model.downloadedURL != nil { Button("Show saved copy") { model.revealDownload() } }
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 30).padding(.bottom, 20)
        .task { model.activate() }
        .onDisappear { model.deactivate() }
        .onChange(of: model.provider) { showingSync = false }
        .sheet(isPresented: Binding(get: { model.syncPlan != nil }, set: { if !$0 { model.dismissSyncPreview() } })) {
            if let plan = model.syncPlan {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Review two-way sync").font(.title2)
                    Text("\(plan.pair.localRoot.path) ↔ \(plan.pair.remoteFolderName)").font(.caption).textSelection(.enabled)
                    Text("Changed files are rechecked before transfer. Local replacements retain backups. Conflicts are reported without overwriting either copy; deletions are never propagated.").font(.caption).foregroundStyle(.secondary)
                    if plan.changes.isEmpty { Text("The paired folders are up to date.").padding() }
                    List(plan.changes) { action in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(action.path).font(.headline)
                            Text(action.kind.rawValue).foregroundStyle(action.kind == .conflict ? Color.orange : Color.secondary)
                            if !action.detail.isEmpty { Text(action.detail).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    HStack { Spacer(); Button("Cancel") { model.dismissSyncPreview() }; Button("Apply sync") { model.applySync() }.buttonStyle(.borderedProminent).disabled(model.transferBusy || plan.changes.isEmpty) }
                }.padding(24).frame(width: 640, height: 500)
            }
        }
        .sheet(isPresented: $showingSyncReport) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sync conflicts").font(.title2)
                Text("Resolve competing edits manually, then preview again. For a missing file, restore it manually or remove it from both sides. Removing and recreating the pairing resets its baseline.").font(.caption)
                List(model.syncIssues, id: \.self) { Text($0).textSelection(.enabled) }
                HStack { Button("Show local backups") { model.showSyncBackups() }; Spacer(); Button("Done") { showingSyncReport = false } }
            }.padding(24).frame(width: 620, height: 440)
        }
    }

    private var syncControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Upload files…") { model.uploadFiles() }.disabled(model.transferBusy)
                if model.syncPair == nil {
                    Button("Pair local folder…") { model.chooseSyncFolder() }.disabled(model.transferBusy)
                } else {
                    Button("Preview sync") { model.previewSync() }.disabled(model.transferBusy)
                    Button("Remove pairing") { model.removeSyncPair() }.disabled(model.transferBusy)
                    Button("Local backups") { model.showSyncBackups() }
                }
                Spacer()
                if !model.syncIssues.isEmpty { Button("\(model.syncIssues.count) conflicts…") { showingSyncReport = true } }
            }.controlSize(.small)
            if let pair = model.syncPair {
                Text("\(pair.localRoot.path) ↔ \(pair.remoteFolderName)").font(.caption).foregroundStyle(.secondary).lineLimit(1).help(pair.localRoot.path)
                Toggle("Sync this pairing every minute while OpenFiles is open", isOn: Binding(get: { model.automaticSync }, set: { model.setAutomaticSync($0) }))
                    .font(.caption).toggleStyle(.checkbox)
                Text("Automatic sync pauses on conflicts or provider changes and starts off each launch. Hidden files and symbolic links are excluded.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var registration: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup("App registration", isExpanded: $model.showingRegistration) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.provider == .googleDrive
                         ? "Use a Google Cloud OAuth client with application type Desktop app and enable the Drive API. Add your account as a test user while the consent app is in testing."
                         : "Use a Microsoft Entra app registration supporting the accounts you want to connect. Add http://localhost/callback under Mobile and desktop applications and enable public client flows.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextField(model.provider == .googleDrive ? "Google OAuth client ID" : "Microsoft application (client) ID", text: $model.clientID)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("OAuth client ID")
                    if model.provider == .googleDrive {
                        SecureField("Desktop client secret, if supplied by Google", text: $model.clientSecret)
                            .textFieldStyle(.roundedBorder)
                    }
                    Toggle("Enable uploads and two-way sync", isOn: $model.writeAccess)
                    Text("Reconnect after changing permissions. Write access allows OpenFiles to modify files in this account; sync operates only on your explicitly paired folder.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("Registration details and sign-in tokens are stored in this Mac’s Keychain. Microsoft desktop apps do not need a client secret.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }.disabled(model.connectionBusy)

            HStack {
                if model.authenticating {
                    ProgressView().controlSize(.small)
                    Text("Finish sign-in in your browser.").font(.system(size: 12))
                    Button("Cancel sign-in") { model.cancelSignIn() }
                } else {
                    Button(model.connected ? "Save and reconnect" : "Connect \(model.provider.displayName)") { model.connect() }
                        .buttonStyle(.borderedProminent).tint(.primary)
                        .disabled(model.connectionBusy || model.transferBusy || model.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.canDisconnect || model.disconnecting {
                        Button(model.disconnecting ? "Disconnecting…" : "Disconnect") { model.disconnect() }.disabled(model.connectionBusy)
                    }
                    Spacer()
                    if model.loadingConfiguration || model.disconnecting { ProgressView().controlSize(.small) }
                }
            }.controlSize(.small)
            if model.connected {
                Text("Disconnect removes saved sign-in on this Mac. To revoke the app’s access, use your provider’s account settings.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(15).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(model.folders.isEmpty).help("Parent folder").accessibilityLabel("Parent folder")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        Button(model.provider.displayName) { model.goToRoot() }
                        ForEach(Array(model.folders.enumerated()), id: \.offset) { index, folder in
                            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.secondary)
                            Button(folder.name) { model.goToFolder(at: index) }
                        }
                    }.font(.system(size: 11)).buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh folder").accessibilityLabel("Refresh folder").disabled(model.loading)
            }.padding(12).buttonStyle(.borderless)
            Divider()
            if model.loading && model.items.isEmpty {
                ProgressView("Loading \(model.currentFolderName)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: model.error == nil ? "folder" : "wifi.exclamationmark").font(.system(size: 30, weight: .light))
                    Text(model.error == nil ? "This folder is empty" : "Folder unavailable").font(.headline)
                    Text(model.error == nil ? "Choose another folder or refresh to check for changes." : "Try refreshing, or reconnect if your authorization has expired.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.items) { item in
                    cloudRow(item)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { activate(item) }
                        .contextMenu {
                            if item.isFolder { Button("Open folder") { model.openFolder(item) } }
                            else if item.canDownload { Button("Save copy…") { model.saveCopy(item) }.disabled(model.transferBusy) }
                            if item.webURL != nil { Button("Open in browser") { model.openOnWeb(item) } }
                        }
                }.listStyle(.inset)
            }
            Divider()
            HStack {
                Text("\(model.items.count) items").foregroundStyle(.secondary)
                Spacer()
                if model.loading { ProgressView().controlSize(.mini) }
                else if model.nextPageToken != nil { Button("Load more") { model.loadMore() } }
            }.font(.system(size: 11)).padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.09)))
    }

    private func cloudRow(_ item: CloudItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isFolder ? "folder" : "doc").font(.system(size: 19)).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 12)).lineLimit(1)
                Text(model.currentLocation.path).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(model.currentLocation.path)
                if !item.isFolder && !item.canDownload {
                    Text(item.webURL == nil ? "Download unavailable" : "Open on the provider’s website").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 10)
            FileLocationTag(location: model.currentLocation)
            if let size = item.size, !item.isFolder {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            }
            if let modified = item.modified {
                Text(modified, style: .date).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            }
            if item.isFolder { Button("Open") { model.openFolder(item) }.frame(width: 100) }
            else if item.canDownload { Button("Save copy…") { model.saveCopy(item) }.disabled(model.transferBusy).frame(width: 100) }
            else if item.webURL != nil { Button("Open in browser") { model.openOnWeb(item) }.frame(width: 100) }
        }.padding(.vertical, 5).buttonStyle(.borderless)
    }

    private var disconnected: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(.secondary)
            Text(model.authenticating ? "Waiting for sign-in" : "Your cloud files, in OpenFiles").font(.system(size: 17, weight: .medium))
            Text("Connect one account per provider to browse folders and save local copies. Enable write access to upload files and pair a folder for two-way sync. No provider sync app is required.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }.padding(25).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func activate(_ item: CloudItem) {
        if item.isFolder { model.openFolder(item) }
        else if item.canDownload { model.saveCopy(item) }
        else { model.openOnWeb(item) }
    }
}
