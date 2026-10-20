import SwiftUI
import AppKit
import CryptoKit
import OpenFilesCloud

struct CloudFolder: Identifiable {
    let id: String
    let name: String
}

/// Remote navigation never enters the local browser, index, or organization pipeline.
@MainActor
final class CloudBrowserModel: ObservableObject {
    @Published private(set) var provider: CloudProvider = .googleDrive
    @Published var clientID = ""
    @Published var clientSecret = ""
    @Published var writeAccess = false
    @Published private(set) var connectedForWriting = false
    @Published private(set) var uploading = false
    @Published private(set) var syncing = false
    @Published private(set) var syncPair: CloudSyncPair?
    @Published private(set) var syncPlan: CloudSyncPlan?
    @Published private(set) var syncIssues: [String] = []
    @Published private(set) var automaticSync = false
    @Published var showingRegistration = true
    @Published private(set) var connected = false
    @Published private(set) var loadingConfiguration = false
    @Published private(set) var authenticating = false
    @Published private(set) var disconnecting = false
    @Published private(set) var loading = false
    @Published private(set) var downloading = false
    @Published private(set) var downloadName = ""
    @Published private(set) var items: [CloudItem] = []
    @Published private(set) var folders: [CloudFolder] = []
    @Published private(set) var nextPageToken: String?
    @Published private(set) var error: String?
    @Published private(set) var status = "Connect an account to browse its files."
    @Published private(set) var downloadedURL: URL?

    private let syncEngine = CloudSyncEngine(directory: CloudSyncDigest.stateDirectory, digest: CloudSyncDigest.compute)
    private var uploadTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var automaticTask: Task<Void, Never>?

    private let credentialStore = KeychainCloudStore()
    private let authenticator = CloudAuthenticator()
    private var client: CloudClient?
    private var clients: [CloudProvider: CloudClient] = [:]
    private var configurationTask: Task<Void, Never>?
    private var authenticationTask: Task<Void, Never>?
    private var authenticationCleanupTask: Task<Void, Never>?
    private var listingTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var accountGeneration = UUID()
    private var listingGeneration = UUID()
    private var downloadGeneration = UUID()

    var transferBusy: Bool { uploading || syncing || downloading }
    var connectionBusy: Bool { loadingConfiguration || authenticating || disconnecting }
    var canDisconnect: Bool { client != nil || error != nil }
    var currentFolderName: String { folders.last?.name ?? provider.displayName }

    func activate() {
        loadSyncPair()
        if connected { refresh() }
        else if client == nil { loadConfiguration() }
    }

    func selectProvider(_ value: CloudProvider) {
        guard provider != value, !disconnecting else { return }
        cancelActiveWork()
        provider = value; connected = false; connectedForWriting = false; client = nil
        clientID = ""; clientSecret = ""; writeAccess = false; showingRegistration = true
        syncPair = nil; syncPlan = nil; syncIssues = []; loadSyncPair()
        clearListing(); downloadedURL = nil
        status = "Connect an account to browse its files."
        loadConfiguration()
    }

    private func loadConfiguration() {
        configurationTask?.cancel()
        accountGeneration = UUID()
        let generation = accountGeneration, selectedProvider = provider
        let pendingCleanup = authenticationCleanupTask
        loadingConfiguration = true; error = nil
        configurationTask = Task {
            defer { if accountGeneration == generation { loadingConfiguration = false } }
            do {
                await pendingCleanup?.value
                try Task.checkCancellation()
                let config = try await credentialStore.loadConfiguration(for: selectedProvider)
                guard !Task.isCancelled, accountGeneration == generation else { return }
                clientID = config?.clientID ?? ""; clientSecret = config?.clientSecret ?? ""
                writeAccess = config?.writeAccess ?? false; connectedForWriting = config?.writeAccess ?? false
                guard let config else { connected = false; showingRegistration = true; return }
                let savedClient = clients[selectedProvider] ?? CloudClient(configuration: config, store: credentialStore)
                let hasAuthorization = try await savedClient.isConnected()
                guard !Task.isCancelled, accountGeneration == generation else { return }
                client = savedClient; clients[selectedProvider] = savedClient; connected = hasAuthorization
                showingRegistration = !hasAuthorization
                if hasAuthorization { refresh() }
            } catch {
                guard !Task.isCancelled, accountGeneration == generation else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func connect() {
        guard !connectionBusy, !transferBusy else { return }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { error = "Enter the client ID from your app registration."; return }
        cancelActiveWork()
        let generation = accountGeneration, selectedProvider = provider
        let config = CloudConfiguration(provider: selectedProvider, clientID: id,
                                        clientSecret: selectedProvider == .googleDrive ? clientSecret : nil, writeAccess: writeAccess)
        let previousClient = client
        let newClient = CloudClient(configuration: config, store: credentialStore)
        let pendingCleanup = authenticationCleanupTask
        let pendingListing = listingTask, pendingDownload = downloadTask
        let pendingUpload = uploadTask, pendingSync = syncTask
        connected = false; clearListing(); error = nil; authenticating = true
        status = "Complete sign-in in your browser."
        authenticationTask = Task {
            defer { if accountGeneration == generation { authenticating = false } }
            do {
                await pendingCleanup?.value
                try Task.checkCancellation()
                // A registration change must never reuse another client's authorization.
                if let previousClient { try await previousClient.disconnect() }
                else { try await newClient.disconnect() }
                await pendingListing?.value
                await pendingDownload?.value
                await pendingUpload?.value; await pendingSync?.value
                try Task.checkCancellation()
                client = newClient; clients[selectedProvider] = newClient
                try await credentialStore.saveConfiguration(config)
                try Task.checkCancellation()
                try await authenticator.signIn(client: newClient, provider: selectedProvider)
                guard !Task.isCancelled, accountGeneration == generation else { return }
                connected = true; connectedForWriting = config.writeAccess; showingRegistration = false
                status = "Connected to \(selectedProvider.displayName)."
                refresh()
            } catch {
                guard !Task.isCancelled, accountGeneration == generation else { return }
                self.error = error.localizedDescription
                status = "Sign-in did not complete."
            }
        }
    }

    func disconnect() {
        guard !disconnecting else { return }
        cancelActiveWork()
        let generation = accountGeneration, selectedProvider = provider, activeClient = client
        let pendingCleanup = authenticationCleanupTask
        let pendingListing = listingTask, pendingDownload = downloadTask
        let pendingUpload = uploadTask, pendingSync = syncTask
        connected = false; connectedForWriting = false; clearListing(); downloadedURL = nil; error = nil
        disconnecting = true; status = "Disconnecting…"
        configurationTask = Task {
            defer { if accountGeneration == generation { disconnecting = false } }
            do {
                await pendingCleanup?.value
                try Task.checkCancellation()
                if let activeClient { try await activeClient.disconnect() }
                else { try await credentialStore.remove(for: selectedProvider) }
                await pendingListing?.value
                await pendingDownload?.value
                await pendingUpload?.value; await pendingSync?.value
                guard !Task.isCancelled, accountGeneration == generation else { return }
                status = "Disconnected on this Mac. You can also revoke access in your provider’s account settings."
            } catch {
                guard !Task.isCancelled, accountGeneration == generation else { return }
                self.error = error.localizedDescription
                status = "Saved sign-in could not be removed. Try Disconnect again."
            }
        }
    }

    func openFolder(_ item: CloudItem) {
        guard item.isFolder, connected else { return }
        folders.append(CloudFolder(id: item.id, name: item.name)); refresh()
    }

    func goBack() { guard !folders.isEmpty else { return }; folders.removeLast(); refresh() }
    func goToRoot() { folders = []; refresh() }
    func goToFolder(at index: Int) { folders = Array(folders.prefix(index + 1)); refresh() }

    func refresh() { loadPage(append: false) }
    func loadMore() { guard nextPageToken != nil, !loading else { return }; loadPage(append: true) }

    private func loadPage(append: Bool) {
        guard connected, let client else { return }
        listingTask?.cancel(); listingGeneration = UUID()
        let generation = listingGeneration, account = accountGeneration
        let folder = folders.last?.id, token = append ? nextPageToken : nil
        loading = true; error = nil
        if !append { items = []; nextPageToken = nil }
        listingTask = Task {
            defer { if listingGeneration == generation { loading = false } }
            do {
                let page = try await client.items(folderID: folder, pageToken: token)
                guard !Task.isCancelled, listingGeneration == generation, accountGeneration == account else { return }
                var seen = Set<String>()
                items = ((append ? items : []) + page.items).filter { seen.insert($0.id).inserted }
                nextPageToken = page.nextPageToken
                status = "\(items.count) items loaded from \(provider.displayName)."
            } catch {
                guard !Task.isCancelled, listingGeneration == generation, accountGeneration == account else { return }
                self.error = error.localizedDescription
                status = "Couldn’t load this folder. Refresh or reconnect to try again."
                handleExpiredConnection(error)
            }
        }
    }

    func saveCopy(_ item: CloudItem) {
        guard connected, item.canDownload, !transferBusy, let client else { return }
        let panel = NSSavePanel()
        panel.title = "Save a copy from \(provider.displayName)"
        panel.message = "This downloads a local copy. Choose a new filename; existing files will not be replaced."
        panel.nameFieldStringValue = item.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            error = "A file already exists there. Choose a different name or folder."; return
        }
        downloadGeneration = UUID()
        let generation = downloadGeneration, account = accountGeneration
        downloading = true; downloadName = item.name; error = nil; downloadedURL = nil
        downloadTask = Task {
            defer { if downloadGeneration == generation { downloading = false; downloadName = "" } }
            do {
                try await client.download(item, to: destination)
                guard !Task.isCancelled, downloadGeneration == generation, accountGeneration == account else { return }
                downloadedURL = destination
                status = "Saved a copy to \(destination.path). Edits to this copy are local."
            } catch {
                guard !Task.isCancelled, downloadGeneration == generation, accountGeneration == account else { return }
                self.error = error.localizedDescription
                handleExpiredConnection(error)
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel(); downloadTask = nil; downloadGeneration = UUID()
        downloading = false; downloadName = ""; status = "Download cancelled."
    }

    func openOnWeb(_ item: CloudItem) {
        guard let url = item.webURL, url.scheme == "https", let host = url.host?.lowercased() else { return }
        // Defense in depth: the core also validates provider links before returning items.
        let allowed = provider == .googleDrive
            ? ["drive.google.com", "docs.google.com"].contains(host)
            : host == "onedrive.live.com" || host == "1drv.ms" || host.hasSuffix(".sharepoint.com")
        guard allowed else { error = "This item’s web link could not be verified."; return }
        NSWorkspace.shared.open(url)
    }

    func revealDownload() { if let downloadedURL { NSWorkspace.shared.activateFileViewerSelecting([downloadedURL]) } }

    func cancelSignIn() {
        guard authenticating else { return }
        cancelActiveWork(); status = "Sign-in cancelled."
    }

    func deactivate() {
        // A requested disconnect must finish even if the user leaves this section.
        if !disconnecting && !automaticSync { cancelActiveWork() }
    }

    private func handleExpiredConnection(_ error: Error) {
        if case CloudError.connectionRequired = error {
            connected = false; connectedForWriting = false; setAutomaticSync(false); clearListing()
            status = "Authorization expired or was revoked. Connect again to continue."
        }
    }

    func cancelActiveWork() {
        uploadTask?.cancel(); syncTask?.cancel(); automaticTask?.cancel(); automaticSync = false
        uploading = false; syncing = false; syncPlan = nil
        let wasAuthenticating = authenticating, activeClient = client, pendingSignIn = authenticationTask
        configurationTask?.cancel(); authenticationTask?.cancel(); listingTask?.cancel(); downloadTask?.cancel()
        authenticator.cancel()
        accountGeneration = UUID(); listingGeneration = UUID(); downloadGeneration = UUID()
        loadingConfiguration = false; authenticating = false; disconnecting = false; loading = false; downloading = false
        downloadName = ""
        if wasAuthenticating, let activeClient {
            // Invalidate a late token response as well as stopping the browser listener.
            authenticationCleanupTask = Task {
                await pendingSignIn?.value
                try? await activeClient.disconnect()
            }
        }
    }

    private func clearListing() { items = []; folders = []; nextPageToken = nil }
}

extension CloudBrowserModel {
    func uploadFiles() {
        guard connected, connectedForWriting, !transferBusy, let client else { return }
        let panel = NSOpenPanel(); panel.title = "Upload files to \(currentFolderName)"
        panel.message = "Selected filenames and file contents will be sent to \(provider.displayName). Existing cloud files will not be replaced."
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let sources = panel.urls, folderID = folders.last?.id, account = accountGeneration
        uploading = true; error = nil; syncPlan = nil
        uploadTask = Task {
            defer { if accountGeneration == account { uploading = false } }
            var completed = 0, failures: [String] = []
            for source in sources {
                if Task.isCancelled { break }
                status = "Uploading \(source.lastPathComponent)…"
                do {
                    _ = try await client.upload(source, folderID: folderID, name: source.lastPathComponent)
                    completed += 1
                } catch is CancellationError { break }
                catch { failures.append("\(source.lastPathComponent): \(error.localizedDescription)") }
            }
            guard accountGeneration == account else { return }
            status = "Uploaded \(completed) of \(sources.count) files." + (Task.isCancelled ? " Check the cloud folder before retrying a cancelled transfer." : "")
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
            refresh()
        }
    }

    func cancelUpload() { uploadTask?.cancel() }

    private func loadSyncPair() {
        let selectedProvider = provider
        Task {
            do {
                let pair = try await syncEngine.pairs().first { $0.provider == selectedProvider }
                if provider == selectedProvider { syncPair = pair }
            } catch { if provider == selectedProvider { self.error = error.localizedDescription } }
        }
    }

    func chooseSyncFolder() {
        guard connected, connectedForWriting, !transferBusy, syncPair == nil, let client else { return }
        let panel = NSOpenPanel(); panel.title = "Pair a local folder with \(currentFolderName)"
        panel.message = "Two-way sync includes files in subfolders. Preview before applying. Deletions remain manual; conflicts need your review. Save or close files in their editors first."
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let root = panel.url else { return }
        let appData = CloudSyncDigest.stateDirectory.deletingLastPathComponent().resolvingSymlinksInPath().path
        let path = root.resolvingSymlinksInPath().path
        guard path != appData, !path.hasPrefix(appData + "/"), !appData.hasPrefix(path + "/") else {
            error = "Choose a folder outside OpenFiles application data and the private vault."; return
        }
        let account = accountGeneration, selectedProvider = provider, remoteID = folders.last?.id, name = currentFolderName
        syncing = true; error = nil
        syncTask = Task {
            defer { if accountGeneration == account { syncing = false } }
            do {
                let pair = try await syncEngine.pair(localRoot: root, remoteFolderID: remoteID, remoteFolderName: name,
                                                     provider: selectedProvider, remote: client)
                guard accountGeneration == account else { return }
                syncPair = pair; syncPlan = nil; syncIssues = []
                status = "Folder paired. Preview sync to review uploads and downloads."
            } catch { if accountGeneration == account { self.error = error.localizedDescription } }
        }
    }

    func removeSyncPair() {
        guard !transferBusy, let pair = syncPair else { return }
        setAutomaticSync(false)
        let account = accountGeneration
        syncing = true
        syncTask = Task {
            defer { if accountGeneration == account { syncing = false } }
            do {
                try await syncEngine.removePair(pair)
                guard accountGeneration == account else { return }
                syncPair = nil; syncPlan = nil; syncIssues = []
                status = "Pairing removed. Local files, cloud files, and sync backups are retained."
            } catch { if accountGeneration == account { self.error = error.localizedDescription } }
        }
    }

    func previewSync() { runSync(applyAutomatically: false) }
    func dismissSyncPreview() { syncPlan = nil }

    private func runSync(applyAutomatically: Bool) {
        guard connected, connectedForWriting, !transferBusy, !connectionBusy, let pair = syncPair, let client else { return }
        let account = accountGeneration
        syncing = true; error = nil; status = "Comparing the paired folders…"
        syncTask = Task {
            defer { if accountGeneration == account { syncing = false } }
            do {
                let plan = try await syncEngine.preview(pair, remote: client)
                guard !Task.isCancelled, accountGeneration == account else { return }
                if applyAutomatically {
                    let report = try await syncEngine.apply(plan, remote: client)
                    guard !Task.isCancelled, accountGeneration == account else { return }
                    presentSyncReport(report)
                } else {
                    syncPlan = plan
                    status = "Sync preview: \(plan.changes.count) changes or conflicts."
                }
            } catch is CancellationError { }
            catch {
                guard accountGeneration == account else { return }
                self.error = error.localizedDescription; setAutomaticSync(false)
            }
        }
    }

    func applySync() {
        guard !transferBusy, let plan = syncPlan, let client else { return }
        let account = accountGeneration
        syncing = true; syncPlan = nil; error = nil; status = "Syncing paired folders…"
        syncTask = Task {
            defer { if accountGeneration == account { syncing = false } }
            do {
                let report = try await syncEngine.apply(plan, remote: client)
                guard !Task.isCancelled, accountGeneration == account else { return }
                presentSyncReport(report)
            } catch is CancellationError { }
            catch { if accountGeneration == account { self.error = error.localizedDescription; setAutomaticSync(false) } }
        }
    }

    private func presentSyncReport(_ report: CloudSyncReport) {
        syncIssues = report.conflicts
        status = "Sync finished: \(report.transferred) transfers, \(report.conflicts.count) conflicts, \(report.backups.count) local backups."
        if !report.conflicts.isEmpty { setAutomaticSync(false); status += " Automatic sync is paused." }
        refresh()
    }

    func cancelSync() { syncTask?.cancel(); setAutomaticSync(false); status = "Stopping sync. Preview again to review the current state." }

    func setAutomaticSync(_ enabled: Bool) {
        automaticTask?.cancel(); automaticTask = nil; automaticSync = false
        guard enabled, connected, connectedForWriting, syncPair != nil else { return }
        automaticSync = true
        automaticTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.automaticSync else { return }
                if self.syncPlan == nil { self.runSync(applyAutomatically: true) }
            }
        }
    }

    func showSyncBackups() {
        let folder = CloudSyncDigest.stateDirectory.appendingPathComponent("Backups")
        if FileManager.default.fileExists(atPath: folder.path) { NSWorkspace.shared.open(folder) }
        else { status = "No local files have been backed up by sync yet." }
    }
}

private enum CloudSyncDigest {
    static var stateDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenFiles/CloudSync", isDirectory: true)
    }
    static func compute(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation(); hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
