import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The sync engine uses this boundary so reconciliation can be tested without accounts.
public protocol CloudSyncRemote: Sendable {
    func identity() async throws -> String
    func items(folderID: String?, pageToken: String?) async throws -> CloudPage
    func metadata(id: String) async throws -> CloudItem
    func createFolder(name: String, parentID: String?) async throws -> CloudItem
    func upload(_ source: URL, folderID: String?, name: String, replacing: CloudItem?) async throws -> CloudItem
    func download(_ item: CloudItem, to destination: URL) async throws
}

extension CloudClient {
    static let googleFields = "id,name,mimeType,size,modifiedTime,webViewLink,version,capabilities(canDownload)"
    static let microsoftFields = "id,name,size,folder,file,remoteItem,lastModifiedDateTime,webUrl,eTag"

    public func identity() async throws -> String {
        let current = generation
        let url = configuration.provider == .googleDrive
            ? "https://www.googleapis.com/drive/v3/about?fields=user(permissionId)"
            : "https://graph.microsoft.com/v1.0/me/drive?$select=id"
        let (data, _) = try await authenticatedSend(URLRequest(url: URL(string: url)!), generation: current)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let identifier = configuration.provider == .googleDrive
            ? (object?["user"] as? [String: Any])?["permissionId"] as? String : object?["id"] as? String
        guard let identifier, !identifier.isEmpty else { throw CloudError.invalidResponse }
        return configuration.provider.rawValue + ":" + identifier
    }

    public func metadata(id: String) async throws -> CloudItem {
        let current = generation, path = try Self.pathComponent(id)
        let base = configuration.provider == .googleDrive
            ? "https://www.googleapis.com/drive/v3/files/\(path)"
            : "https://graph.microsoft.com/v1.0/me/drive/" + (id == "root" ? "root" : "items/\(path)")
        let (data, response) = try await authenticatedSend(URLRequest(url: itemURL(base)), generation: current)
        return try decodeItem(data, response: response)
    }

    public func createFolder(name: String, parentID: String? = nil) async throws -> CloudItem {
        let current = generation
        try await requireWriteAccess()
        try Self.validateName(name)
        try await refuseNameCollision(name, folderID: parentID)
        let google = configuration.provider == .googleDrive
        let parent = try parentID.map { "items/\(try Self.pathComponent($0))" } ?? "root"
        let base = google ? "https://www.googleapis.com/drive/v3/files"
            : "https://graph.microsoft.com/v1.0/me/drive/\(parent)/children"
        let body: [String: Any] = google
            ? ["name": name, "mimeType": "application/vnd.google-apps.folder", "parents": [parentID ?? "root"]]
            : ["name": name, "folder": [:], "@microsoft.graph.conflictBehavior": "fail"]
        var request = URLRequest(url: itemURL(base)); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await authenticatedSend(request, generation: current)
        return try decodeItem(data, response: response)
    }

    /// New files use bounded chunks; updates use a single conditional request so
    /// If-Match protects the actual replacement, not merely upload-session creation.
    public func upload(_ source: URL, folderID: String? = nil, name: String, replacing: CloudItem? = nil) async throws -> CloudItem {
        let current = generation
        try await requireWriteAccess()
        try Self.validateName(name)
        guard source.isFileURL else { throw CloudError.unsafeURL }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let before = try source.resourceValues(forKeys: keys)
        guard before.isRegularFile == true, before.isSymbolicLink != true else {
            throw CloudError.unsupportedUpload("Choose a regular file. Symbolic links and folders must not be uploaded as file contents.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesUpload-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = directory.appendingPathComponent("payload")
        try FileManager.default.copyItem(at: source, to: snapshot)
        let after = try source.resourceValues(forKeys: keys)
        let copied = try snapshot.resourceValues(forKeys: keys)
        guard after.isRegularFile == true, after.isSymbolicLink != true,
              copied.isRegularFile == true, copied.isSymbolicLink != true,
              before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
            throw CloudError.sourceChanged
        }
        let size = Int64(try snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        try ensureCurrent(current)
        if let replacing {
            guard replacing.canDownload, !replacing.isFolder, let revision = replacing.revision else {
                throw CloudError.conflict("This item cannot be safely replaced.")
            }
            let latest = try await metadata(id: replacing.id)
            guard latest.revision == revision, latest.name == replacing.name, let etag = latest.etag, !etag.isEmpty else {
                throw CloudError.conflict("The remote file changed, or the provider did not supply a conditional-update tag.")
            }
            if configuration.provider == .oneDrive && size > 250 * 1024 * 1024 {
                throw CloudError.unsupportedUpload("OneDrive conditional updates are limited to 250 MB. Upload this file under a new name to preserve the remote version.")
            }
            let path = try Self.pathComponent(replacing.id)
            let base = configuration.provider == .googleDrive
                ? "https://www.googleapis.com/upload/drive/v3/files/\(path)?uploadType=media"
                : "https://graph.microsoft.com/v1.0/me/drive/items/\(path)/content"
            var request = URLRequest(url: itemURL(base))
            request.httpMethod = configuration.provider == .googleDrive ? "PATCH" : "PUT"
            request.setValue(etag, forHTTPHeaderField: "If-Match")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(size), forHTTPHeaderField: "Content-Length")
            request.timeoutInterval = 3600
            request.setValue("Bearer \(try await accessToken(generation: current))", forHTTPHeaderField: "Authorization")
            let (data, response) = try await transport.upload(request, fromFile: snapshot)
            try ensureCurrent(current)
            try Self.checkStatus(response.statusCode)
            return try decodeItem(data, response: response)
        }
        try await refuseNameCollision(name, folderID: folderID)
        try ensureCurrent(current)
        if size == 0 { return try await uploadEmpty(name: name, folderID: folderID, current: current) }
        return try await uploadChunks(snapshot, size: size, name: name, folderID: folderID, current: current)
    }

    private func uploadChunks(_ file: URL, size: Int64, name: String, folderID: String?, current: UUID) async throws -> CloudItem {
        let google = configuration.provider == .googleDrive
        let parent = try folderID.map { "items/\(try Self.pathComponent($0))" } ?? "root"
        let pathName = try Self.pathComponent(name)
        let base = google ? "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable"
            : "https://graph.microsoft.com/v1.0/me/drive/\(parent):/\(pathName):/createUploadSession"
        var start = URLRequest(url: google ? itemURL(base) : URL(string: base)!)
        start.httpMethod = "POST"
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if google {
            start.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
            start.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
        }
        let payload: [String: Any] = google ? ["name": name, "parents": [folderID ?? "root"]]
            : ["item": ["name": name, "@microsoft.graph.conflictBehavior": "fail"]]
        start.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await authenticatedSend(start, generation: current)
        let session = google ? response.value(forHTTPHeaderField: "Location")
            : (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["uploadUrl"] as? String
        guard let session else { throw CloudError.invalidResponse }
        let sessionURL = try uploadSessionURL(session)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset: Int64 = 0
        // 5 MiB is a multiple of Google's 256 KiB and Microsoft's 320 KiB units.
        while offset < size {
            try ensureCurrent(current)
            let length = Int(min(Int64(5 * 1024 * 1024), size - offset))
            guard let bytes = try handle.read(upToCount: length), bytes.count == length else { throw CloudError.sourceChanged }
            var chunk = URLRequest(url: sessionURL); chunk.httpMethod = "PUT"
            chunk.httpBody = bytes
            chunk.setValue(String(length), forHTTPHeaderField: "Content-Length")
            chunk.setValue("bytes \(offset)-\(offset + Int64(length) - 1)/\(size)", forHTTPHeaderField: "Content-Range")
            chunk.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            if google { chunk.setValue("Bearer \(try await accessToken(generation: current))", forHTTPHeaderField: "Authorization") }
            // Microsoft upload URLs carry their own authorization. Never forward Graph tokens.
            let (body, reply) = try await transport.send(chunk)
            try ensureCurrent(current)
            offset += Int64(length)
            if offset == size {
                try Self.checkStatus(reply.statusCode)
                guard reply.statusCode == 200 || reply.statusCode == 201 else { throw CloudError.invalidResponse }
                return try decodeItem(body, response: reply)
            }
            if google {
                guard reply.statusCode == 308,
                      reply.value(forHTTPHeaderField: "Range") == "bytes=0-\(offset - 1)" else {
                    try Self.checkStatus(reply.statusCode); throw CloudError.invalidResponse
                }
            } else {
                try Self.checkStatus(reply.statusCode)
                let body = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                guard reply.statusCode == 202, let ranges = body?["nextExpectedRanges"] as? [String],
                      ranges == ["\(offset)-"] else { throw CloudError.invalidResponse }
            }
        }
        throw CloudError.invalidResponse
    }

    private func uploadEmpty(name: String, folderID: String?, current: UUID) async throws -> CloudItem {
        var request: URLRequest
        if configuration.provider == .googleDrive {
            request = URLRequest(url: itemURL("https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart"))
            request.httpMethod = "POST"
            let boundary = "OpenFiles-\(UUID())"
            request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let metadata = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [folderID ?? "root"]])
            var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
            body.append(metadata)
            body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--\(boundary)--\r\n".utf8))
            request.httpBody = body
        } else {
            let parent = try folderID.map { "items/\(try Self.pathComponent($0))" } ?? "root"
            request = URLRequest(url: itemURL("https://graph.microsoft.com/v1.0/me/drive/\(parent):/\(try Self.pathComponent(name)):/content?%40microsoft.graph.conflictBehavior=fail"))
            request.httpMethod = "PUT"; request.httpBody = Data()
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await authenticatedSend(request, generation: current)
        return try decodeItem(data, response: response)
    }

    private func requireWriteAccess() async throws {
        guard configuration.writeAccess, let token = try await store.load(for: configuration.provider) else {
            throw CloudError.writePermissionRequired
        }
        let scopes = Set((token.scopes ?? "").lowercased().split(separator: " ").map(String.init))
        let granted = configuration.provider == .googleDrive ? scopes.contains("https://www.googleapis.com/auth/drive")
            : scopes.contains("files.readwrite") || scopes.contains("https://graph.microsoft.com/files.readwrite")
        guard granted else { throw CloudError.writePermissionRequired }
    }

    private func refuseNameCollision(_ name: String, folderID: String?) async throws {
        var next: String?, seen = Set<String>()
        repeat {
            let page = try await items(folderID: folderID, pageToken: next)
            guard !page.items.contains(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
                throw CloudError.conflict("An item named \(name) already exists. Choose a different name.")
            }
            next = page.nextPageToken
            if let next, !seen.insert(next).inserted { throw CloudError.invalidResponse }
        } while next != nil
    }

    private func itemURL(_ base: String) -> URL {
        // Graph mutation endpoints return a driveItem by default; not every
        // content/session endpoint supports the OData $select query option.
        if configuration.provider == .oneDrive { return URL(string: base)! }
        var components = URLComponents(string: base)!
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: configuration.provider == .googleDrive ? "fields" : "$select",
                                  value: configuration.provider == .googleDrive ? Self.googleFields : Self.microsoftFields))
        components.queryItems = query
        return components.url!
    }

    private func decodeItem(_ data: Data, response: HTTPURLResponse) throws -> CloudItem {
        do {
            if configuration.provider == .googleDrive {
                let item = try JSONDecoder().decode(GoogleItem.self, from: data)
                return CloudItem(id: item.id, name: item.name, isFolder: item.mimeType == "application/vnd.google-apps.folder",
                    size: item.size.flatMap(Int64.init), modified: Self.date(item.modifiedTime), webURL: Self.webURL(item.webViewLink, provider: .googleDrive),
                    canDownload: !item.mimeType.hasPrefix("application/vnd.google-apps.") && item.capabilities?.canDownload != false,
                    revision: item.version, etag: response.value(forHTTPHeaderField: "ETag"))
            }
            let item = try JSONDecoder().decode(MicrosoftItem.self, from: data)
            return CloudItem(id: item.id, name: item.name, isFolder: item.folder != nil && item.remoteItem == nil,
                size: item.size, modified: Self.date(item.lastModifiedDateTime), webURL: Self.webURL(item.webUrl, provider: .oneDrive),
                canDownload: item.file != nil && item.remoteItem == nil, revision: item.eTag, etag: item.eTag)
        } catch { throw CloudError.invalidResponse }
    }

    private func uploadSessionURL(_ string: String) throws -> URL {
        let url = try Self.downloadURL(string), host = url.host!.lowercased()
        if configuration.provider == .googleDrive {
            guard host == "www.googleapis.com", url.path.hasPrefix("/upload/drive/v3/files") else { throw CloudError.unsafeURL }
        } else {
            let domains = ["1drv.com", "sharepoint.com", "sharepoint-df.com", "storage.live.com", "onedrive.live.com"]
            guard domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { throw CloudError.unsafeURL }
        }
        return url
    }

    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CloudError.conflict("A filename contains unsupported characters.")
        }
    }
}
