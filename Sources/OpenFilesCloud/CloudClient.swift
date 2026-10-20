import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One explicitly connected account per provider. Cloud metadata stays outside the local index.
public actor CloudClient: CloudSyncRemote {
    public let configuration: CloudConfiguration
    let store: any CloudCredentialStore
    let transport: any CloudHTTPTransport
    var generation = UUID()
    private var refreshTask: Task<CloudToken, Error>?
    private var refreshID: UUID?

    public init(configuration: CloudConfiguration, store: any CloudCredentialStore,
                transport: any CloudHTTPTransport = URLSessionCloudTransport()) {
        self.configuration = configuration; self.store = store; self.transport = transport
    }

    public func authorizationURL(redirectURI: String, state: String, challenge: String) throws -> URL {
        guard !configuration.clientID.isEmpty else { throw CloudError.invalidConfiguration }
        try Self.validateRedirect(redirectURI)
        guard !state.isEmpty, challenge.count == 43,
              challenge.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { throw CloudError.invalidCallback }
        var values = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        if configuration.provider == .googleDrive {
            values += [URLQueryItem(name: "access_type", value: "offline"), URLQueryItem(name: "prompt", value: "consent select_account")]
        } else {
            values += [URLQueryItem(name: "response_mode", value: "query"), URLQueryItem(name: "prompt", value: "select_account")]
        }
        var components = URLComponents(string: configuration.provider == .googleDrive
            ? "https://accounts.google.com/o/oauth2/v2/auth"
            : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        components.queryItems = values
        guard let url = components.url else { throw CloudError.invalidConfiguration }
        return url
    }

    public func completeSignIn(code: String, redirectURI: String, verifier: String) async throws {
        guard !configuration.clientID.isEmpty else { throw CloudError.invalidConfiguration }
        try Self.validateRedirect(redirectURI)
        guard !code.isEmpty, (43...128).contains(verifier.count),
              verifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) })
        else { throw CloudError.invalidCallback }
        refreshTask?.cancel(); refreshTask = nil; refreshID = nil
        generation = UUID(); let current = generation
        let token = try await Self.requestToken(configuration: configuration, transport: transport, values: [
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": redirectURI, "code_verifier": verifier
        ], existingRefreshToken: nil)
        try ensureCurrent(current)
        try await store.save(token, for: configuration.provider)
        try ensureCurrent(current)
    }

    public func isConnected() async throws -> Bool {
        let current = generation
        let token = try await store.load(for: configuration.provider)
        try ensureCurrent(current)
        return token != nil
    }

    /// Removes this app's saved authorization. Revocation at the provider remains a separate action.
    public func disconnect() async throws {
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil; refreshID = nil
        try await store.remove(for: configuration.provider)
    }

    public func items(folderID: String? = nil, pageToken: String? = nil) async throws -> CloudPage {
        let current = generation
        let request = try listingRequest(folderID: folderID, pageToken: pageToken)
        let (data, _) = try await authenticatedSend(request, generation: current)
        try ensureCurrent(current)
        do {
            switch configuration.provider {
            case .googleDrive:
                let response = try JSONDecoder().decode(GoogleList.self, from: data)
                let items = response.files.map { item in
                    let folder = item.mimeType == "application/vnd.google-apps.folder"
                    let native = item.mimeType.hasPrefix("application/vnd.google-apps.")
                    return CloudItem(id: item.id, name: item.name, isFolder: folder,
                        size: item.size.flatMap(Int64.init), modified: Self.date(item.modifiedTime),
                        webURL: Self.webURL(item.webViewLink, provider: .googleDrive),
                        canDownload: !native && item.capabilities?.canDownload != false, revision: item.version)
                }
                return CloudPage(items: Self.sorted(items), nextPageToken: response.nextPageToken?.nilIfEmpty)
            case .oneDrive:
                let response = try JSONDecoder().decode(MicrosoftList.self, from: data)
                // Reject forged pagination links before a caller can offer Load more.
                if let link = response.nextLink { _ = try Self.microsoftPageURL(link) }
                let items = response.value.map { item in
                    // Remote/shared references require a separate drive identity; do not treat them as own-drive IDs.
                    let remote = item.remoteItem != nil
                    return CloudItem(id: item.id, name: item.name, isFolder: item.folder != nil && !remote,
                        size: item.size, modified: Self.date(item.lastModifiedDateTime),
                        webURL: Self.webURL(item.webUrl, provider: .oneDrive),
                        canDownload: item.file != nil && !remote, revision: item.eTag, etag: item.eTag)
                }
                return CloudPage(items: Self.sorted(items), nextPageToken: response.nextLink?.nilIfEmpty)
            }
        } catch let error as CloudError { throw error }
        catch { throw CloudError.invalidResponse }
    }

    /// Downloads to a caller-chosen, new local file. Never uses a remote name as a local path.
    public func download(_ item: CloudItem, to destination: URL) async throws {
        guard item.canDownload, !item.isFolder else { throw CloudError.unsupportedDownload }
        guard destination.isFileURL else { throw CloudError.unsafeURL }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CloudError.destinationExists }
        let current = generation
        let pathID = try Self.pathComponent(item.id)
        let url = URL(string: configuration.provider == .googleDrive
            ? "https://www.googleapis.com/drive/v3/files/\(pathID)?alt=media"
            : "https://graph.microsoft.com/v1.0/me/drive/items/\(pathID)/content")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await accessToken(generation: current))", forHTTPHeaderField: "Authorization")
        var redirected = false
        var refreshed = false
        var redirects = 0
        while true {
            try ensureCurrent(current)
            let (temporary, response) = try await transport.download(request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try ensureCurrent(current)
            if response.statusCode == 401 && !redirected && !refreshed {
                refreshed = true
                request.setValue("Bearer \(try await accessToken(forceRefresh: true, generation: current))", forHTTPHeaderField: "Authorization")
                continue
            }
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                guard redirects < 5, let location = response.value(forHTTPHeaderField: "Location") else { throw CloudError.invalidResponse }
                let next = try Self.downloadURL(location)
                // A preauthenticated URL has its own authorization. Never forward our OAuth bearer token.
                request = URLRequest(url: next)
                redirected = true; redirects += 1
                continue
            }
            if response.statusCode == 401 && !redirected {
                try await invalidate(generation: current)
                throw CloudError.connectionRequired
            }
            try Self.checkStatus(response.statusCode)
            // Only a complete response is accepted; partial content without a requested Range is unexpected.
            guard response.statusCode == 200 else { throw CloudError.invalidResponse }
            try ensureCurrent(current)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw CloudError.destinationExists }
            // Stage beside the destination so copy failures never leave a partial user-visible file.
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".openfiles-download-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: temporary, to: staging)
            try ensureCurrent(current)
            // moveItem refuses existing destinations, including races after the preflight check.
            try FileManager.default.moveItem(at: staging, to: destination)
            return
        }
    }

    private var scope: String { configuration.scope }

    private func listingRequest(folderID: String?, pageToken: String?) throws -> URLRequest {
        switch configuration.provider {
        case .googleDrive:
            let folder = folderID ?? "root"
            guard !folder.isEmpty else { throw CloudError.invalidResponse }
            let escaped = folder.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            components.queryItems = [
                URLQueryItem(name: "q", value: "'\(escaped)' in parents and trashed = false"),
                URLQueryItem(name: "pageSize", value: "100"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,modifiedTime,webViewLink,version,capabilities(canDownload))"),
                URLQueryItem(name: "orderBy", value: "folder,name_natural")
            ]
            if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            return URLRequest(url: components.url!)
        case .oneDrive:
            if let pageToken { return URLRequest(url: try Self.microsoftPageURL(pageToken)) }
            let path = try folderID.map { "items/\(try Self.pathComponent($0))" } ?? "root"
            var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/drive/\(path)/children")!
            components.queryItems = [
                URLQueryItem(name: "$top", value: "100"),
                URLQueryItem(name: "$select", value: "id,name,size,folder,file,remoteItem,lastModifiedDateTime,webUrl,eTag")
            ]
            return URLRequest(url: components.url!)
        }
    }

    func authenticatedSend(_ original: URLRequest, generation current: UUID) async throws -> (Data, HTTPURLResponse) {
        var request = original
        request.setValue("Bearer \(try await accessToken(generation: current))", forHTTPHeaderField: "Authorization")
        var result = try await transport.send(request)
        try ensureCurrent(current)
        if result.1.statusCode == 401 {
            request.setValue("Bearer \(try await accessToken(forceRefresh: true, generation: current))", forHTTPHeaderField: "Authorization")
            result = try await transport.send(request)
            try ensureCurrent(current)
        }
        if result.1.statusCode == 401 {
            try await invalidate(generation: current)
            throw CloudError.connectionRequired
        }
        try Self.checkStatus(result.1.statusCode)
        return result
    }

    func accessToken(forceRefresh: Bool = false, generation current: UUID) async throws -> String {
        try ensureCurrent(current)
        guard let saved = try await store.load(for: configuration.provider) else { throw CloudError.connectionRequired }
        try ensureCurrent(current)
        if !forceRefresh && saved.expiresAt.timeIntervalSinceNow > 60 { return saved.accessToken }
        guard let refreshToken = saved.refreshToken, !refreshToken.isEmpty else {
            try await invalidate(generation: current)
            throw CloudError.connectionRequired
        }
        let task: Task<CloudToken, Error>
        let identifier: UUID
        if let existing = refreshTask, let existingID = refreshID {
            task = existing; identifier = existingID
        }
        else {
            identifier = UUID()
            task = Task {
                let token = try await Self.requestToken(configuration: self.configuration, transport: self.transport,
                    values: ["grant_type": "refresh_token", "refresh_token": refreshToken], existingRefreshToken: refreshToken, existingScopes: saved.scopes)
                try self.ensureCurrent(current)
                // A shared renewal persists once, even when multiple requests await it.
                try await self.store.save(token, for: self.configuration.provider)
                try self.ensureCurrent(current)
                return token
            }
            refreshTask = task; refreshID = identifier
        }
        do {
            let token = try await task.value
            try ensureCurrent(current)
            if refreshID == identifier { refreshTask = nil; refreshID = nil }
            return token.accessToken
        } catch {
            if refreshID == identifier { refreshTask = nil; refreshID = nil }
            if case CloudError.connectionRequired = error {
                try await invalidate(generation: current)
            }
            throw error
        }
    }

    private func invalidate(generation current: UUID) async throws {
        try ensureCurrent(current)
        try await store.remove(for: configuration.provider)
    }

    func ensureCurrent(_ current: UUID) throws {
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
    }

    private static func requestToken(configuration: CloudConfiguration, transport: any CloudHTTPTransport,
                                     values: [String: String], existingRefreshToken: String?, existingScopes: String? = nil) async throws -> CloudToken {
        var values = values
        values["client_id"] = configuration.clientID
        if configuration.provider == .googleDrive, let secret = configuration.clientSecret { values["client_secret"] = secret }
        if configuration.provider == .oneDrive { values["scope"] = configuration.scope }
        let endpoint = configuration.provider == .googleDrive
            ? "https://oauth2.googleapis.com/token"
            : "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(values).data(using: .utf8)
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        if !(200..<300).contains(response.statusCode) {
            let failure = try? JSONDecoder().decode(TokenFailure.self, from: data)
            if failure?.error == "invalid_grant" { throw CloudError.connectionRequired }
            if response.statusCode == 429 { throw CloudError.rateLimited }
            if response.statusCode >= 500 { throw CloudError.serviceUnavailable(response.statusCode) }
            throw CloudError.authenticationFailed
        }
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !response.access_token.isEmpty, response.expires_in > 0,
              response.token_type.lowercased() == "bearer" else { throw CloudError.invalidResponse }
        return CloudToken(accessToken: response.access_token,
            refreshToken: response.refresh_token?.nilIfEmpty ?? existingRefreshToken,
            expiresAt: Date().addingTimeInterval(response.expires_in),
            scopes: response.scope ?? (values["grant_type"] == "authorization_code" ? configuration.scope : existingScopes))
    }

    private static func form(_ values: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return values.keys.sorted().map { "\($0.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(values[$0]!.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&")
    }

    private static func validateRedirect(_ value: String) throws {
        guard let url = URLComponents(string: value), url.scheme == "http",
              ["127.0.0.1", "localhost"].contains(url.host ?? ""),
              let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw CloudError.invalidCallback }
    }

    static func pathComponent(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != ".." else { throw CloudError.invalidResponse }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else { throw CloudError.invalidResponse }
        return encoded
    }

    private static func microsoftPageURL(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value), components.scheme == "https",
              components.host?.lowercased() == "graph.microsoft.com", components.port == nil || components.port == 443,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.path.hasPrefix("/v1.0/me/drive/"), components.path.hasSuffix("/children"),
              !components.path.split(separator: "/").contains(".."), let url = components.url else { throw CloudError.unsafeURL }
        return url
    }

    static func downloadURL(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value), components.scheme == "https",
              let host = components.host?.lowercased(), host.contains("."),
              host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }),
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil, components.fragment == nil,
              let url = components.url else { throw CloudError.unsafeURL }
        return url
    }

    static func webURL(_ value: String?, provider: CloudProvider) -> URL? {
        guard let value, let components = URLComponents(string: value), components.scheme == "https",
              components.user == nil, components.password == nil, components.port == nil || components.port == 443,
              let host = components.host?.lowercased() else { return nil }
        let domains = provider == .googleDrive ? ["drive.google.com", "docs.google.com"]
            : ["onedrive.live.com", "1drv.ms", "sharepoint.com", "sharepoint-df.com", "office.com"]
        guard domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return components.url
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func sorted(_ items: [CloudItem]) -> [CloudItem] {
        items.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func checkStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401: throw CloudError.connectionRequired
        case 403: throw CloudError.accessDenied
        case 404: throw CloudError.notFound
        case 409, 412: throw CloudError.conflict("The remote item changed or the destination already exists. Refresh and review again.")
        case 429: throw CloudError.rateLimited
        default: throw CloudError.serviceUnavailable(status)
        }
    }
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double
    let token_type: String
    let scope: String?
}
private struct TokenFailure: Decodable { let error: String }
private struct GoogleList: Decodable {
    let files: [GoogleItem]
    let nextPageToken: String?
}
struct GoogleItem: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let modifiedTime: String?
    let version: String?
    let webViewLink: String?
    let capabilities: Capabilities?
    struct Capabilities: Decodable { let canDownload: Bool? }
}
private struct MicrosoftList: Decodable {
    let value: [MicrosoftItem]
    let nextLink: String?
    enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink" }
}
struct MicrosoftItem: Decodable {
    let id: String
    let name: String
    let size: Int64?
    let lastModifiedDateTime: String?
    let eTag: String?
    let webUrl: String?
    let folder: Facet?
    let file: Facet?
    let remoteItem: Facet?
    struct Facet: Decodable {}
}
private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
