import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenFilesCloud

// These scenarios use no accounts, network requests, or personal folders.
private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message) }
}

private func expectError(_ operation: () async throws -> Void,
                        matching predicate: (Error) -> Bool) async throws {
    do { try await operation() }
    catch {
        guard predicate(error) else { throw CheckFailure("Unexpected error: \(error)") }
        return
    }
    throw CheckFailure("Expected the operation to fail")
}

private actor MemoryStore: CloudCredentialStore {
    private var tokens: [CloudProvider: CloudToken] = [:]
    private(set) var saves = 0
    private var loads = 0
    private var loadWaiter: (Int, CheckedContinuation<Void, Never>)?
    init(provider: CloudProvider? = nil, token: CloudToken? = nil) {
        if let provider, let token { tokens[provider] = token }
    }
    func load(for provider: CloudProvider) async throws -> CloudToken? {
        loads += 1
        if let (count, waiter) = loadWaiter, loads >= count { loadWaiter = nil; waiter.resume() }
        return tokens[provider]
    }
    func save(_ token: CloudToken, for provider: CloudProvider) async throws { saves += 1; tokens[provider] = token }
    func remove(for provider: CloudProvider) async throws { tokens.removeValue(forKey: provider) }
    func waitForLoads(_ count: Int) async {
        if loads >= count { return }
        await withCheckedContinuation { loadWaiter = (count, $0) }
    }
}

private struct Reply: Sendable {
    enum Kind: Sendable, Equatable { case send, download }
    let kind: Kind
    let status: Int
    let body: Data
    let headers: [String: String]
    init(_ body: String, status: Int = 200, headers: [String: String] = [:], kind: Kind = .send) {
        self.kind = kind; self.status = status; self.body = Data(body.utf8); self.headers = headers
    }
}

private actor MockTransport: CloudHTTPTransport {
    private var replies: [Reply]
    private var requests: [URLRequest] = []
    private var files: [URL] = []
    init(_ replies: [Reply]) { self.replies = replies }
    private func take(_ request: URLRequest, kind: Reply.Kind) throws -> Reply {
        guard !replies.isEmpty else { throw CheckFailure("Unexpected request: \(request.httpMethod ?? "GET") \(request.url?.path ?? "")") }
        let reply = replies.removeFirst()
        guard reply.kind == kind else { throw CheckFailure("Used the wrong transport operation") }
        requests.append(request)
        return reply
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = try take(request, kind: .send)
        return (reply.body, response(for: request, reply: reply))
    }
    func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let reply = try take(request, kind: .download)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesCloudTransfer-\(UUID())")
        try reply.body.write(to: url)
        files.append(url)
        return (url, response(for: request, reply: reply))
    }
    private func response(for request: URLRequest, reply: Reply) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
    }
    func recorded() -> [URLRequest] { requests }
    func finish() throws {
        try expect(replies.isEmpty, "Expected HTTP requests were not executed")
        try expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "A transfer temporary file was not cleaned up")
    }
}

private actor PausedTransport: CloudHTTPTransport {
    private let body: String
    private var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var ready: CheckedContinuation<Void, Never>?
    private var request: URLRequest?
    init(body: String) { self.body = body }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        ready?.resume(); ready = nil
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        throw CheckFailure("Unexpected download")
    }
    func waitForRequest() async {
        if request != nil { return }
        await withCheckedContinuation { ready = $0 }
    }
    func resume() {
        let response = HTTPURLResponse(url: request!.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        pending?.resume(returning: (Data(body.utf8), response)); pending = nil
    }
}

private actor ConcurrentRefreshTransport: CloudHTTPTransport {
    private var renewal: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var refreshes = 0
    private(set) var listings = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        if request.httpMethod == "POST" {
            refreshes += 1
            if refreshes == 1 {
                await withCheckedContinuation { continuation in
                    renewal = continuation; started?.resume(); started = nil
                }
            }
            return (Data(#"{"access_token":"renewed","refresh_token":"rotated","expires_in":3600,"token_type":"Bearer"}"#.utf8), response)
        }
        listings += 1
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed", "Concurrent request used an expired token")
        return (Data(#"{"value":[]}"#.utf8), response)
    }
    func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) { throw CheckFailure("Unexpected download") }
    func waitForRefresh() async {
        if renewal != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { renewal?.resume(); renewal = nil }
}

private func liveToken(refresh: String? = "fake-refresh") -> CloudToken {
    CloudToken(accessToken: "fake-access", refreshToken: refresh, expiresAt: Date().addingTimeInterval(3600))
}

private func client(_ provider: CloudProvider, replies: [Reply], token: CloudToken? = liveToken()) -> (CloudClient, MemoryStore, MockTransport) {
    let store = MemoryStore(provider: provider, token: token)
    let transport = MockTransport(replies)
    return (CloudClient(configuration: CloudConfiguration(provider: provider, clientID: "test-client"), store: store, transport: transport), store, transport)
}

private func query(_ url: URL) -> [String: String] {
    Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
}

private func form(_ request: URLRequest) throws -> [String: String] {
    guard let data = request.httpBody, let text = String(data: data, encoding: .utf8) else { throw CheckFailure("Missing form body") }
    var values: [String: String] = [:]
    for pair in text.split(separator: "&") {
        let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let key = String(pieces[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
              let value = String(pieces[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
            throw CheckFailure("Malformed form body")
        }
        values[key] = value
    }
    return values
}

private func withDirectory(_ operation: (URL) async throws -> Void) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesCloudChecks-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: url) }
    try await operation(url)
}

private func authorizationRequests() async throws {
    for provider in CloudProvider.allCases {
        let (api, _, transport) = client(provider, replies: [], token: nil)
        let redirect = provider == .googleDrive ? "http://127.0.0.1:48517/callback" : "http://localhost:48517/callback"
        let url = try await api.authorizationURL(redirectURI: redirect, state: "state+with&reserved=value", challenge: String(repeating: "a", count: 43))
        let parameters = query(url)
        try expect(url.scheme == "https", "Authorization must use HTTPS")
        try expect(url.host == (provider == .googleDrive ? "accounts.google.com" : "login.microsoftonline.com"), "Incorrect authorization host")
        try expect(parameters["client_id"] == "test-client", "Missing client ID")
        try expect(parameters["response_type"] == "code", "Expected authorization-code flow")
        try expect(parameters["code_challenge_method"] == "S256", "Expected PKCE S256")
        try expect(parameters["code_challenge"] == String(repeating: "a", count: 43), "Challenge changed")
        try expect(parameters["state"] == "state+with&reserved=value", "State was not encoded losslessly")
        try expect(parameters["redirect_uri"] == redirect, "Callback URI changed")
        let scope = parameters["scope"] ?? ""
        if provider == .googleDrive {
            try expect(scope == "https://www.googleapis.com/auth/drive.readonly", "Google scope must remain read-only")
            try expect(parameters["access_type"] == "offline", "Google should request a refresh token")
        } else {
            try expect(Set(scope.split(separator: " ").map(String.init)) == Set(["Files.Read", "offline_access"]), "Unexpected Microsoft permissions")
        }
        try await transport.finish()
    }
}

private func callbackValidation() async throws {
    let host = "127.0.0.1:48517", state = "random+state&value"
    func parse(_ target: String, headers: String = "Host: 127.0.0.1:48517", method: String = "GET", version: String = "HTTP/1.1", body: String = "") -> CloudOAuthCallback {
        CloudOAuthCallback.parse(Data("\(method) \(target) \(version)\r\n\(headers)\r\n\r\n\(body)".utf8), expectedHost: host, expectedState: state)
    }
    let valid = "/callback?code=code%2B%26%3D%2F&state=random%2Bstate%26value"
    try expect(parse(valid) == .code("code+&=/"), "Valid code/state were not decoded losslessly")
    try expect(parse("/callback?error=access_denied&state=random%2Bstate%26value") == .denied, "Provider denial must be recognized only with valid state")
    try expect(parse(valid, headers: "host: 127.0.0.1:48517", version: "HTTP/1.0") == .code("code+&=/"), "Valid header case/version refused")
    for target in [
        "/favicon.ico?state=random%2Bstate%26value&code=x",
        "/callback?code=x&state=wrong",
        "/callback?code=x",
        "/callback?code=&state=random%2Bstate%26value",
        "/callback?code=x&state=random%2Bstate%26value&state=random%2Bstate%26value",
        "/callback?code=x&%73tate=random%2Bstate%26value&state=random%2Bstate%26value",
        "/callback?code=x&error=access_denied&state=random%2Bstate%26value",
        "/callback?error=access_denied&state=wrong",
        "/callback?error=&state=random%2Bstate%26value",
        "/callback?code=x&state=random%2Bstate%26value#fragment",
        "http://127.0.0.1:48517/callback?code=x&state=random%2Bstate%26value",
        "//attacker.example/callback?code=x&state=random%2Bstate%26value"
    ] { try expect(parse(target) == .invalidRequest, "Unsafe callback target accepted") }
    for headers in ["Host: attacker.example", "Host: 127.0.0.1:48518", "Host: 127.0.0.1:48517\r\nHost: 127.0.0.1:48517", "X-Host: 127.0.0.1:48517", " Host: 127.0.0.1:48517"] {
        try expect(parse(valid, headers: headers) == .invalidRequest, "Unsafe Host header accepted")
    }
    try expect(parse(valid, method: "POST") == .invalidRequest, "Unexpected callback method accepted")
    try expect(parse(valid, version: "HTTP/2.0") == .invalidRequest, "Unexpected callback version accepted")
    try expect(parse(valid, headers: "X-Header: harmless", body: "Host: 127.0.0.1:48517") == .invalidRequest, "Body supplied a missing Host header")
    try expect(parse(valid, body: "Host: attacker.example") == .code("code+&=/"), "Body was mistaken for a request header")
    let incomplete = Data("GET \(valid) HTTP/1.1\r\nHost: \(host)\r\n".utf8)
    try expect(CloudOAuthCallback.parse(incomplete, expectedHost: host, expectedState: state) == .invalidRequest, "Incomplete headers accepted")
    try expect(parse(valid, body: String(repeating: "x", count: 16_384)) == .invalidRequest, "Oversized callback accepted")
}

private func authorizationCodeExchange() async throws {
    let store = MemoryStore()
    let transport = MockTransport([Reply(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}"#)])
    let api = CloudClient(configuration: CloudConfiguration(provider: .googleDrive, clientID: "client+&=", clientSecret: "desktop+secret&="), store: store, transport: transport)
    let verifier = String(repeating: "v", count: 64)
    try await api.completeSignIn(code: "code+&= /", redirectURI: "http://127.0.0.1:48517/callback", verifier: verifier)
    let requests = await transport.recorded()
    try expect(requests.count == 1, "Expected one token exchange")
    let request = requests[0], fields = try form(request)
    try expect(request.url?.host == "oauth2.googleapis.com", "Incorrect Google token endpoint")
    try expect(request.httpMethod == "POST", "Token exchange must POST")
    try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "Token exchange should not send an API bearer token")
    try expect(fields["client_id"] == "client+&=", "Client ID form encoding changed its contents")
    try expect(fields["client_secret"] == "desktop+secret&=", "Desktop credential form encoding changed its contents")
    try expect(fields["code"] == "code+&= /", "Authorization code form encoding changed its contents")
    try expect(fields["code_verifier"] == verifier, "Missing PKCE verifier")
    try expect(fields["grant_type"] == "authorization_code", "Incorrect grant type")
    let token = try await store.load(for: .googleDrive)
    try expect(token?.accessToken == "new-access" && token?.refreshToken == "new-refresh", "Exchange did not persist tokens")
    try expect(token!.expiresAt > Date().addingTimeInterval(3500), "Expiry was not calculated")
    try await transport.finish()
}

private func googleFolderPages() async throws {
    let (api, _, transport) = client(.googleDrive, replies: [
        Reply(#"{"files":[{"id":"folder","name":"Projects","mimeType":"application/vnd.google-apps.folder"},{"id":"file","name":"notes.txt","mimeType":"text/plain","size":"12","modifiedTime":"2026-01-02T03:04:05.000Z","webViewLink":"https://drive.google.com/file/d/file/view"},{"id":"doc","name":"Plan","mimeType":"application/vnd.google-apps.document","webViewLink":"https://docs.google.com/document/d/doc/edit"},{"id":"shortcut","name":"Link","mimeType":"application/vnd.google-apps.shortcut"}],"nextPageToken":"next+&=/"}"#),
        Reply(#"{"files":[]}"#)
    ])
    let page = try await api.items()
    try expect(page.items.count == 4, "Google files were not decoded")
    try expect(page.items.first { $0.id == "folder" }?.isFolder == true, "Google folder classification failed")
    let file = page.items.first { $0.id == "file" }
    try expect(file?.size == 12 && file?.modified != nil && file?.canDownload == true, "Google file metadata was lost")
    try expect(page.items.first { $0.id == "doc" }?.canDownload == false, "Workspace documents are not byte downloads")
    try expect(page.items.first { $0.id == "shortcut" }?.canDownload == false, "Shortcuts must not be downloaded as bytes")
    try expect(page.nextPageToken == "next+&=/", "Google page token changed")
    let last = try await api.items(pageToken: page.nextPageToken)
    try expect(last.items.isEmpty && last.nextPageToken == nil, "Empty final page was not handled")
    let requests = await transport.recorded()
    try expect(query(requests[0].url!)["q"]?.contains("'root' in parents") == true, "Google listing must start at the account root")
    try expect(query(requests[0].url!)["q"]?.contains("trashed = false") == true, "Trashed files should be excluded")
    try expect(query(requests[1].url!)["pageToken"] == "next+&=/", "Pagination token was not encoded losslessly")
    try expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fake-access" }, "Google API listing needs authentication")
    try await transport.finish()
}

private func graphFolderPages() async throws {
    let next = "https://graph.microsoft.com/v1.0/me/drive/root/children?$skiptoken=next%2Bpage"
    let body = #"{"value":[{"id":"folder","name":"Photos","folder":{"childCount":2}},{"id":"file","name":"image.png","size":42,"file":{"mimeType":"image/png"},"lastModifiedDateTime":"2026-01-02T03:04:05Z","webUrl":"https://onedrive.live.com/?id=file"}],"@odata.nextLink":"NEXT"}"#.replacingOccurrences(of: "NEXT", with: next)
    let (api, _, transport) = client(.oneDrive, replies: [Reply(body), Reply(#"{"value":[]}"#)])
    let page = try await api.items()
    try expect(page.items.count == 2, "OneDrive files were not decoded")
    try expect(page.items.first { $0.id == "folder" }?.isFolder == true, "OneDrive folder classification failed")
    try expect(page.items.first { $0.id == "file" }?.size == 42, "OneDrive numeric size was lost")
    try expect(page.nextPageToken == next, "Graph continuation changed")
    let last = try await api.items(pageToken: page.nextPageToken)
    try expect(last.items.isEmpty && last.nextPageToken == nil, "Empty Graph final page was not handled")
    let requests = await transport.recorded()
    try expect(requests[0].url?.path == "/v1.0/me/drive/root/children", "OneDrive listing must use own-drive root")
    try expect(requests[1].url?.absoluteString == next, "Graph continuation was not used")
    try await transport.finish()
}

private func refreshRotationAndPreservation() async throws {
    for replacement in [true, false] {
        let body = replacement ? #"{"access_token":"refreshed","refresh_token":"rotated","expires_in":3600,"token_type":"Bearer"}"# : #"{"access_token":"refreshed","expires_in":3600,"token_type":"Bearer"}"#
        let expired = CloudToken(accessToken: "expired", refreshToken: "original+refresh&", expiresAt: .distantPast)
        let (api, store, transport) = client(.oneDrive, replies: [Reply(body), Reply(#"{"value":[]}"#)], token: expired)
        _ = try await api.items()
        let requests = await transport.recorded(), fields = try form(requests[0])
        try expect(requests[0].url?.host == "login.microsoftonline.com", "Wrong refresh endpoint")
        try expect(fields["grant_type"] == "refresh_token" && fields["refresh_token"] == "original+refresh&", "Refresh grant encoding failed")
        try expect(fields["client_secret"] == nil, "Microsoft native client must not use a client secret")
        try expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer refreshed", "API did not use refreshed access token")
        let saved = try await store.load(for: .oneDrive)
        try expect(saved?.refreshToken == (replacement ? "rotated" : "original+refresh&"), "Refresh token rotation/preservation failed")
        try await transport.finish()
    }
}

private func revokedRefreshRequiresConnection() async throws {
    let expired = CloudToken(accessToken: "expired", refreshToken: "revoked", expiresAt: .distantPast)
    let (api, store, transport) = client(.googleDrive, replies: [Reply(#"{"error":"invalid_grant","error_description":"revoked"}"#, status: 400)], token: expired)
    try await expectError({ _ = try await api.items() }, matching: { if case CloudError.connectionRequired = $0 { return true }; return false })
    let saved = try await store.load(for: .googleDrive)
    try expect(saved == nil, "Revoked credentials must be removed")
    try await transport.finish()
}

private func missingConnectionDoesNotRequest() async throws {
    let (api, _, transport) = client(.oneDrive, replies: [], token: nil)
    let connected = try await api.isConnected()
    try expect(!connected, "Missing token reported connected")
    try await expectError({ _ = try await api.items() }, matching: { if case CloudError.connectionRequired = $0 { return true }; return false })
    try await transport.finish()
}

private func maliciousGraphContinuationRejected() async throws {
    for url in ["https://attacker.example/v1.0/me/drive/root/children", "http://graph.microsoft.com/v1.0/me/drive/root/children", "https://graph.microsoft.com.evil.example/v1.0/me/drive/root/children", "https://graph.microsoft.com/v1.0/users", "https://user:password@graph.microsoft.com/v1.0/me/drive/root/children"] {
        let (api, _, transport) = client(.oneDrive, replies: [])
        try await expectError({ _ = try await api.items(pageToken: url) }, matching: { if case CloudError.unsafeURL = $0 { return true }; return false })
        try await transport.finish()
    }
}

private func remoteIdentifiersAndNames() async throws {
    let folder = "folder'\\+&/value"
    let (google, _, googleTransport) = client(.googleDrive, replies: [Reply(#"{"files":[]}"#)])
    _ = try await google.items(folderID: folder)
    let googleRequests = await googleTransport.recorded()
    try expect(query(googleRequests[0].url!)["q"] == "'folder\\'\\\\+&/value' in parents and trashed = false", "Google parent ID must be escaped within its query literal")
    try await googleTransport.finish()

    let (microsoft, _, microsoftTransport) = client(.oneDrive, replies: [Reply(#"{"value":[]}"#)])
    _ = try await microsoft.items(folderID: "folder/with?reserved#characters")
    let microsoftRequests = await microsoftTransport.recorded()
    try expect(microsoftRequests[0].url!.absoluteString.contains("items/folder%2Fwith%3Freserved%23characters/children"), "Remote identifier escaped its single path component")
    try await microsoftTransport.finish()

    try await withDirectory { directory in
        let (api, _, transport) = client(.googleDrive, replies: [Reply("content", kind: .download)])
        let chosen = directory.appendingPathComponent("chosen.txt")
        try await api.download(CloudItem(id: "file", name: "../../outside.txt", isFolder: false), to: chosen)
        try expect(FileManager.default.fileExists(atPath: chosen.path), "Download did not use the selected local destination")
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try expect(entries == ["chosen.txt"], "Remote name affected the local filesystem destination")
        try await transport.finish()
    }
}

private func providerErrors() async throws {
    for status in [403, 404, 429, 503] {
        let (api, _, transport) = client(.oneDrive, replies: [Reply(#"{"error":{"message":"untrusted provider text"}}"#, status: status)])
        try await expectError({ _ = try await api.items() }, matching: { error in
            switch (status, error) {
            case (403, CloudError.accessDenied), (404, CloudError.notFound), (429, CloudError.rateLimited), (503, CloudError.serviceUnavailable(503)): return true
            default: return false
            }
        })
        try await transport.finish()
    }
}

private func redirectedDownloadDropsAuthorization() async throws {
    try await withDirectory { directory in
        let (api, _, transport) = client(.oneDrive, replies: [
            Reply("", status: 302, headers: ["Location": "https://download.example.test/temporary-file?opaque=one"], kind: .download),
            Reply("downloaded bytes", kind: .download)
        ])
        let destination = directory.appendingPathComponent("copy.txt")
        try await api.download(CloudItem(id: "file-id", name: "remote.txt", isFolder: false), to: destination)
        let contents = try String(contentsOf: destination)
        try expect(contents == "downloaded bytes", "Download contents changed")
        let requests = await transport.recorded()
        try expect(requests[0].url?.host == "graph.microsoft.com", "Content request must begin at Graph")
        try expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fake-access", "Graph content request needs its bearer token")
        try expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil, "Bearer token leaked to content host")
        try expect(requests[1].url?.host == "download.example.test", "Expected download redirect was not followed")
        try await transport.finish()
    }
}

private func unsafeDownloadRedirectRejected() async throws {
    try await withDirectory { directory in
        let (api, _, transport) = client(.oneDrive, replies: [Reply("", status: 302, headers: ["Location": "http://download.example.test/file"], kind: .download)])
        let destination = directory.appendingPathComponent("copy.txt")
        try await expectError({ try await api.download(CloudItem(id: "file", name: "file.txt", isFolder: false), to: destination) }, matching: { if case CloudError.unsafeURL = $0 { return true }; return false })
        try expect(!FileManager.default.fileExists(atPath: destination.path), "Unsafe transfer published a destination")
        try await transport.finish()
    }
}

private func collisionRefusal() async throws {
    try await withDirectory { directory in
        let (api, _, transport) = client(.googleDrive, replies: [])
        let destination = directory.appendingPathComponent("existing.txt")
        try Data("keep original".utf8).write(to: destination)
        try await expectError({ try await api.download(CloudItem(id: "file", name: "file.txt", isFolder: false), to: destination) }, matching: { if case CloudError.destinationExists = $0 { return true }; return false })
        let contents = try String(contentsOf: destination)
        try expect(contents == "keep original", "Existing file was modified")
        try await transport.finish()
    }
}

private func workspaceDownloadRefused() async throws {
    try await withDirectory { directory in
        let (api, _, transport) = client(.googleDrive, replies: [])
        let item = CloudItem(id: "document", name: "Plan", isFolder: false, canDownload: false)
        try await expectError({ try await api.download(item, to: directory.appendingPathComponent("Plan")) }, matching: { if case CloudError.unsupportedDownload = $0 { return true }; return false })
        try await transport.finish()
    }
}

private func failedDownloadDoesNotPublish() async throws {
    try await withDirectory { directory in
        let (api, _, transport) = client(.googleDrive, replies: [Reply("provider error body", status: 503, kind: .download)])
        let destination = directory.appendingPathComponent("copy.txt")
        try await expectError({ try await api.download(CloudItem(id: "file", name: "file.txt", isFolder: false), to: destination) }, matching: { if case CloudError.serviceUnavailable(503) = $0 { return true }; return false })
        try expect(!FileManager.default.fileExists(atPath: destination.path), "Failed download published provider error bytes")
        try await transport.finish()
    }
}

private func disconnectClearsAuthorization() async throws {
    let (api, store, transport) = client(.oneDrive, replies: [])
    try await api.disconnect()
    let token = try await store.load(for: .oneDrive), connected = try await api.isConnected()
    try expect(token == nil && !connected, "Disconnect did not clear local authorization")
    try await transport.finish()
}

private func disconnectRejectsLateResults() async throws {
    for duringRefresh in [false, true] {
        let token = duringRefresh ? CloudToken(accessToken: "expired", refreshToken: "refresh", expiresAt: .distantPast) : liveToken()
        let body = duringRefresh ? #"{"access_token":"late-token","refresh_token":"late-refresh","expires_in":3600,"token_type":"Bearer"}"# : #"{"value":[]}"#
        let store = MemoryStore(provider: .oneDrive, token: token), transport = PausedTransport(body: body)
        let api = CloudClient(configuration: CloudConfiguration(provider: .oneDrive, clientID: "test-client"), store: store, transport: transport)
        let listing = Task { try await api.items() }
        await transport.waitForRequest()
        try await api.disconnect()
        await transport.resume()
        try await expectError({ _ = try await listing.value }, matching: { $0 is CancellationError })
        let saved = try await store.load(for: .oneDrive)
        try expect(saved == nil, "Late network response restored disconnected credentials")
    }
}

private func concurrentRefresh() async throws {
    let expired = CloudToken(accessToken: "expired", refreshToken: "original", expiresAt: .distantPast)
    let store = MemoryStore(provider: .oneDrive, token: expired), transport = ConcurrentRefreshTransport()
    let api = CloudClient(configuration: CloudConfiguration(provider: .oneDrive, clientID: "test"), store: store, transport: transport)
    let first = Task { try await api.items() }
    await transport.waitForRefresh()
    let second = Task { try await api.items() }
    await store.waitForLoads(2)
    await transport.release()
    _ = try await first.value
    _ = try await second.value
    let refreshes = await transport.refreshes, listings = await transport.listings, saves = await store.saves
    try expect(refreshes == 1 && saves == 1 && listings == 2, "Concurrent callers must share one persisted token renewal")
}

private func unauthorizedRetry() async throws {
    for rejectedAgain in [false, true] {
        let (api, store, transport) = client(.oneDrive, replies: [
            Reply("", status: 401),
            Reply(#"{"access_token":"renewed","expires_in":3600,"token_type":"Bearer"}"#),
            Reply(#"{"value":[]}"#, status: rejectedAgain ? 401 : 200)
        ])
        if rejectedAgain {
            try await expectError({ _ = try await api.items() }, matching: { if case CloudError.connectionRequired = $0 { return true }; return false })
            let token = try await store.load(for: .oneDrive)
            try expect(token == nil, "Repeated unauthorized response must clear the rejected credential")
        } else { _ = try await api.items() }
        let requests = await transport.recorded()
        try expect(requests.count == 3 && requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer renewed", "Unauthorized request must retry exactly once with renewed authorization")
        try await transport.finish()
    }
}

private func cancelledSignIn() async throws {
    let store = MemoryStore(), transport = PausedTransport(body: #"{"access_token":"late","refresh_token":"late-refresh","expires_in":3600,"token_type":"Bearer"}"#)
    let api = CloudClient(configuration: CloudConfiguration(provider: .googleDrive, clientID: "test"), store: store, transport: transport)
    let signIn = Task { try await api.completeSignIn(code: "test-code", redirectURI: "http://127.0.0.1:48517/callback", verifier: String(repeating: "a", count: 43)) }
    await transport.waitForRequest()
    signIn.cancel()
    await transport.resume()
    try await expectError({ try await signIn.value }, matching: { $0 is CancellationError })
    let token = try await store.load(for: .googleDrive)
    try expect(token == nil, "Cancelled sign-in must not store a late token response")
}

@main
private struct Runner {
    static func main() async {
        let scenarios: [(String, () async throws -> Void)] = [
            ("OAuth provider scopes, PKCE and query encoding", authorizationRequests),
            ("Loopback callback validates state, host and request shape", callbackValidation),
            ("Authorization code exchange and form encoding", authorizationCodeExchange),
            ("Google folders, native documents and pagination", googleFolderPages),
            ("OneDrive folders and pagination", graphFolderPages),
            ("Refresh token rotation and preservation", refreshRotationAndPreservation),
            ("Revoked grant clears credentials", revokedRefreshRequiresConnection),
            ("Disconnected listing makes no HTTP request", missingConnectionDoesNotRequest),
            ("Untrusted Graph continuations are refused", maliciousGraphContinuationRejected),
            ("Remote IDs and filenames cannot escape their destinations", remoteIdentifiersAndNames),
            ("Provider errors remain actionable", providerErrors),
            ("OneDrive download redirect strips bearer token", redirectedDownloadDropsAuthorization),
            ("Insecure content redirect is refused", unsafeDownloadRedirectRejected),
            ("Downloads preserve existing destinations", collisionRefusal),
            ("Workspace bytes are not downloaded", workspaceDownloadRefused),
            ("Failed downloads clean temporary files", failedDownloadDoesNotPublish),
            ("Disconnect clears local authorization", disconnectClearsAuthorization),
            ("Disconnect rejects late listings and refreshed credentials", disconnectRejectsLateResults),
            ("Concurrent requests share one persisted refresh", concurrentRefresh),
            ("Unauthorized requests renew once before requiring reconnect", unauthorizedRetry),
            ("Cancelled sign-in rejects late tokens", cancelledSignIn)
        ] + syncScenarios + uploadScenarios
        var failures = 0
        for (name, scenario) in scenarios {
            do { try await scenario(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(scenarios.count) cloud scenarios; \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
