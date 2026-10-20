import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenFilesCloud

private struct UploadFailure: Error { let message: String }
private func assertUpload(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw UploadFailure(message: message) }
}
private actor WriteStore: CloudCredentialStore {
    var token: CloudToken?
    init(scopes: String?) { token = CloudToken(accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(3600), scopes: scopes) }
    func load(for provider: CloudProvider) async throws -> CloudToken? { token }
    func save(_ value: CloudToken, for provider: CloudProvider) async throws { token = value }
    func remove(for provider: CloudProvider) async throws { token = nil }
}
private struct WriteReply: Sendable {
    let status: Int
    let body: String
    var headers: [String: String] = [:]
}
private actor WriteTransport: CloudHTTPTransport {
    private var replies: [WriteReply]
    private var requests: [URLRequest] = []
    private(set) var streamed = false
    init(_ replies: [WriteReply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !replies.isEmpty else { throw UploadFailure(message: "Unexpected HTTP request") }
        requests.append(request)
        let reply = replies.removeFirst()
        return (Data(reply.body.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!)
    }
    func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
        streamed = true
        var request = request; request.httpBody = try Data(contentsOf: file)
        return try await send(request)
    }
    func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) { throw UploadFailure(message: "Unexpected download") }
    func recorded() -> [URLRequest] { requests }
    func finished() throws { try assertUpload(replies.isEmpty, "An expected provider request did not execute") }
}
private let googleFile = #"{"id":"new-id","name":"file.bin","mimeType":"application/octet-stream","size":"1","version":"2"}"#
private let microsoftFile = #"{"id":"new-id","name":"file.bin","file":{},"size":1,"eTag":"\"2\""}"#
private func writeClient(_ provider: CloudProvider, _ replies: [WriteReply], granted: String? = nil, enabled: Bool = true) -> (CloudClient, WriteTransport) {
    let config = CloudConfiguration(provider: provider, clientID: "fixture-client", writeAccess: enabled)
    let transport = WriteTransport(replies)
    return (CloudClient(configuration: config, store: WriteStore(scopes: granted ?? config.scope), transport: transport), transport)
}
private func uploadFixture(_ bytes: Data = Data([1]), _ operation: (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesWriteChecks-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("file.bin")
    try bytes.write(to: source)
    try await operation(source)
}
private func expectUploadFailure(_ operation: () async throws -> Void, match: (Error) -> Bool) async throws {
    do { try await operation() } catch {
        try assertUpload(match(error), "Wrong error type: \(error.localizedDescription)"); return
    }
    throw UploadFailure(message: "Expected upload failure")
}
private func writePermissions() async throws {
    let old = Data(#"{"provider":"googleDrive","clientID":"existing"}"#.utf8)
    let decoded = try JSONDecoder().decode(CloudConfiguration.self, from: old)
    try assertUpload(!decoded.writeAccess, "Legacy registrations must remain read-only")
    for provider in CloudProvider.allCases {
        let config = CloudConfiguration(provider: provider, clientID: "client", writeAccess: true)
        let transport = WriteTransport([])
        let api = CloudClient(configuration: config, store: WriteStore(scopes: nil), transport: transport)
        let url = try await api.authorizationURL(redirectURI: "http://localhost:34567/callback", state: "state", challenge: String(repeating: "a", count: 43))
        let scope = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "scope" }!.value!
        try assertUpload(scope == config.scope && (provider == .googleDrive ? scope.hasSuffix("/drive") : scope.contains("Files.ReadWrite")), "Write consent scope is missing")
        try await uploadFixture { source in
            try await expectUploadFailure({ _ = try await api.upload(source, name: "file.bin") }, match: { if case CloudError.writePermissionRequired = $0 { return true }; return false })
        }
        let requests = await transport.recorded()
        try assertUpload(requests.isEmpty, "An old token was allowed to write without new consent")
    }
}
private func googleChunkedUpload() async throws {
    let chunkSize = 5 * 1024 * 1024
    try await uploadFixture(Data(repeating: 42, count: chunkSize + 13)) { source in
        let (api, transport) = writeClient(.googleDrive, [
            WriteReply(status: 200, body: #"{"files":[]}"#),
            WriteReply(status: 200, body: "", headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture"]),
            WriteReply(status: 308, body: "", headers: ["Range": "bytes=0-\(chunkSize - 1)"]),
            WriteReply(status: 200, body: googleFile)
        ])
        let result = try await api.upload(source, folderID: "parent", name: "file.bin")
        let requests = await transport.recorded()
        let metadata = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: Any]
        try assertUpload(metadata["parents"] as? [String] == ["parent"], "Upload targeted the wrong Google folder")
        try assertUpload(requests[2].httpBody?.count == chunkSize && requests[3].httpBody?.count == 13, "Upload chunks did not respect their bounds")
        try assertUpload(requests[3].value(forHTTPHeaderField: "Content-Range") == "bytes \(chunkSize)-\(chunkSize + 12)/\(chunkSize + 13)", "Wrong final byte range")
        try assertUpload(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access", "Google upload session was not authenticated")
        try assertUpload(result.revision == "2", "Upload returned no usable baseline revision")
        try await transport.finished()
    }
}
private func microsoftUploadCredentials() async throws {
    try await uploadFixture { source in
        let (api, transport) = writeClient(.oneDrive, [
            WriteReply(status: 200, body: #"{"value":[]}"#),
            WriteReply(status: 200, body: #"{"uploadUrl":"https://fixture.up.1drv.com/upload?session=example"}"#),
            WriteReply(status: 201, body: microsoftFile)
        ])
        _ = try await api.upload(source, name: "file.bin")
        let requests = await transport.recorded()
        let object = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: [String: String]]
        try assertUpload(object["item"]?["@microsoft.graph.conflictBehavior"] == "fail", "New upload would overwrite an existing OneDrive file")
        try assertUpload(requests[2].value(forHTTPHeaderField: "Authorization") == nil, "Graph bearer token leaked to an upload URL")
        try assertUpload(requests[2].httpBody == Data([1]), "The wrong source bytes were uploaded")
        try await transport.finished()
    }
}
private func unsafeUploadEndpoints() async throws {
    for provider in CloudProvider.allCases {
        try await uploadFixture { source in
            let initial = WriteReply(status: 200, body: provider == .googleDrive ? #"{"files":[]}"# : #"{"value":[]}"#)
            let session = provider == .googleDrive
                ? WriteReply(status: 200, body: "", headers: ["Location": "https://attacker.example/upload"])
                : WriteReply(status: 200, body: #"{"uploadUrl":"https://attacker.example/upload"}"#)
            let (api, transport) = writeClient(provider, [initial, session])
            try await expectUploadFailure({ _ = try await api.upload(source, name: "file.bin") }, match: { if case CloudError.unsafeURL = $0 { return true }; return false })
            let requests = await transport.recorded()
            try assertUpload(requests.count == 2 && requests.allSatisfy { $0.url?.host != "attacker.example" }, "File contents were sent to an untrusted host")
            try await transport.finished()
        }
    }
}
private func conditionalUpload() async throws {
    for provider in CloudProvider.allCases {
        for stale in [false, true] {
            try await uploadFixture { source in
                let google = provider == .googleDrive
                let original = google ? googleFile.replacingOccurrences(of: #""version":"2""#, with: #""version":"1""#)
                    : microsoftFile.replacingOccurrences(of: #"\"2\""#, with: #"\"1\""#)
                let (api, transport) = writeClient(provider, [
                    WriteReply(status: 200, body: original, headers: ["ETag": "\"1\""]),
                    WriteReply(status: stale ? 412 : 200, body: stale ? "" : (google ? googleFile : microsoftFile))
                ])
                let expected = CloudItem(id: "new-id", name: "file.bin", isFolder: false,
                                         revision: google ? "1" : "\"1\"", etag: "\"1\"")
                if stale {
                    try await expectUploadFailure({ _ = try await api.upload(source, name: "file.bin", replacing: expected) }, match: { if case CloudError.conflict = $0 { return true }; return false })
                } else { _ = try await api.upload(source, name: "file.bin", replacing: expected) }
                let requests = await transport.recorded(), streamed = await transport.streamed
                try assertUpload(streamed && requests[1].value(forHTTPHeaderField: "If-Match") == "\"1\"", "Replacement was not protected at the content-write request")
                try assertUpload(requests[1].httpMethod == (google ? "PATCH" : "PUT"), "Wrong replacement method")
                try await transport.finished()
            }
        }
    }
}
private func duplicateUploadAndMissingETag() async throws {
    try await uploadFixture { source in
        let (api, transport) = writeClient(.googleDrive, [WriteReply(status: 200, body: "{\"files\":[\(googleFile)]}")])
        try await expectUploadFailure({ _ = try await api.upload(source, name: "file.bin") }, match: { if case CloudError.conflict = $0 { return true }; return false })
        try await transport.finished()
        let (other, noTag) = writeClient(.googleDrive, [WriteReply(status: 200, body: googleFile)])
        let item = CloudItem(id: "new-id", name: "file.bin", isFolder: false, revision: "2")
        try await expectUploadFailure({ _ = try await other.upload(source, name: "file.bin", replacing: item) }, match: { if case CloudError.conflict = $0 { return true }; return false })
        try await noTag.finished()
    }
}
private func emptyUploads() async throws {
    for provider in CloudProvider.allCases {
        try await uploadFixture(Data()) { source in
            let google = provider == .googleDrive
            let (api, transport) = writeClient(provider, [WriteReply(status: 200, body: google ? #"{"files":[]}"# : #"{"value":[]}"#),
                                                       WriteReply(status: 201, body: google ? googleFile : microsoftFile)])
            _ = try await api.upload(source, name: "file.bin")
            let requests = await transport.recorded()
            if google {
                try assertUpload(requests[1].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/related") == true, "Empty Google file needs multipart metadata")
            } else {
                let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
                try assertUpload(query.contains { $0.name == "@microsoft.graph.conflictBehavior" && $0.value == "fail" }, "Empty OneDrive creation can overwrite")
            }
            try await transport.finished()
        }
    }
}

let uploadScenarios: [(String, () async throws -> Void)] = [
    ("Write permissions require explicit consent and legacy migration", writePermissions),
    ("Google uploads stream bounded chunks to the selected folder", googleChunkedUpload),
    ("OneDrive upload sessions never receive Graph bearer tokens", microsoftUploadCredentials),
    ("Uploads refuse untrusted session destinations", unsafeUploadEndpoints),
    ("Conditional replacements reject stale provider revisions", conditionalUpload),
    ("Uploads refuse collisions and unguarded replacements", duplicateUploadAndMissingETag),
    ("Empty files upload without overwriting existing names", emptyUploads)
]
