import SwiftUI
import AppKit
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

    var connectionBusy: Bool { loadingConfiguration || authenticating || disconnecting }
    var canDisconnect: Bool { client != nil || error != nil }
    var currentFolderName: String { folders.last?.name ?? provider.displayName }

    func activate() {
        if connected { refresh() }
        else if client == nil { loadConfiguration() }
    }

    func selectProvider(_ value: CloudProvider) {
        guard provider != value, !disconnecting else { return }
        cancelActiveWork()
        provider = value; connected = false; client = nil
        clientID = ""; clientSecret = ""; showingRegistration = true
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
        guard !connectionBusy else { return }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { error = "Enter the client ID from your app registration."; return }
        cancelActiveWork()
        let generation = accountGeneration, selectedProvider = provider
        let config = CloudConfiguration(provider: selectedProvider, clientID: id,
                                        clientSecret: selectedProvider == .googleDrive ? clientSecret : nil)
        let previousClient = client
        let newClient = CloudClient(configuration: config, store: credentialStore)
        let pendingCleanup = authenticationCleanupTask
        let pendingListing = listingTask, pendingDownload = downloadTask
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
                try Task.checkCancellation()
                client = newClient; clients[selectedProvider] = newClient
                try await credentialStore.saveConfiguration(config)
                try Task.checkCancellation()
                try await authenticator.signIn(client: newClient, provider: selectedProvider)
                guard !Task.isCancelled, accountGeneration == generation else { return }
                connected = true; showingRegistration = false
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
        connected = false; clearListing(); downloadedURL = nil; error = nil
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
        guard connected, item.canDownload, !downloading, let client else { return }
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
        if !disconnecting { cancelActiveWork() }
    }

    private func handleExpiredConnection(_ error: Error) {
        if case CloudError.connectionRequired = error {
            connected = false; clearListing()
            status = "Authorization expired or was revoked. Connect again to continue."
        }
    }

    func cancelActiveWork() {
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
