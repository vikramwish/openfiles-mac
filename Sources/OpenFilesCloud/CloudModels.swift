import Foundation

public enum CloudProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case googleDrive, oneDrive
    public var id: String { rawValue }
    public var displayName: String { self == .googleDrive ? "Google Drive" : "OneDrive" }
}

/// Native-app registration details. Persist these in Keychain alongside credentials.
public struct CloudConfiguration: Codable, Sendable {
    public let provider: CloudProvider
    public let clientID: String
    public let clientSecret: String?
    public let writeAccess: Bool
    public init(provider: CloudProvider, clientID: String, clientSecret: String? = nil, writeAccess: Bool = false) {
        self.provider = provider
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret?.isEmpty == false ? clientSecret : nil
        self.writeAccess = writeAccess
    }
    private enum CodingKeys: String, CodingKey { case provider, clientID, clientSecret, writeAccess }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(CloudProvider.self, forKey: .provider)
        clientID = try values.decode(String.self, forKey: .clientID)
        clientSecret = try values.decodeIfPresent(String.self, forKey: .clientSecret)
        writeAccess = try values.decodeIfPresent(Bool.self, forKey: .writeAccess) ?? false
    }
    public var scope: String {
        provider == .googleDrive
            ? "https://www.googleapis.com/auth/drive" + (writeAccess ? "" : ".readonly")
            : (writeAccess ? "Files.ReadWrite" : "Files.Read") + " offline_access"
    }
}

public struct CloudToken: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let scopes: String?
    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scopes: String? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.scopes = scopes
    }
}

public protocol CloudCredentialStore: Sendable {
    func load(for provider: CloudProvider) async throws -> CloudToken?
    func save(_ token: CloudToken, for provider: CloudProvider) async throws
    func remove(for provider: CloudProvider) async throws
}

public struct CloudItem: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let isFolder: Bool
    public let size: Int64?
    public let modified: Date?
    public let webURL: URL?
    public let canDownload: Bool
    public let revision: String?
    public let etag: String?
    public init(id: String, name: String, isFolder: Bool, size: Int64? = nil,
                modified: Date? = nil, webURL: URL? = nil, canDownload: Bool = true,
                revision: String? = nil, etag: String? = nil) {
        self.id = id; self.name = name; self.isFolder = isFolder; self.size = size
        self.modified = modified; self.webURL = webURL; self.canDownload = canDownload && !isFolder
        self.revision = revision; self.etag = etag
    }
}

public struct CloudPage: Sendable {
    public let items: [CloudItem]
    public let nextPageToken: String?
    public init(items: [CloudItem], nextPageToken: String?) {
        self.items = items; self.nextPageToken = nextPageToken
    }
}

public enum CloudError: LocalizedError, Sendable {
    case invalidConfiguration
    case invalidCallback
    case connectionRequired
    case authenticationFailed
    case accessDenied
    case notFound
    case rateLimited
    case serviceUnavailable(Int)
    case invalidResponse
    case unsafeURL
    case unsupportedDownload
    case destinationExists
    case writePermissionRequired
    case conflict(String)
    case unsupportedUpload(String)
    case sourceChanged
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Enter the client ID from a native desktop app registration."
        case .invalidCallback: return "The sign-in response could not be verified. Please connect again."
        case .connectionRequired: return "This account needs to be connected again. Its saved authorization has expired or was revoked."
        case .authenticationFailed: return "Sign-in could not be completed. Check the app registration and try connecting again."
        case .accessDenied: return "The provider denied access. Check the account’s file permissions and the app’s consent."
        case .notFound: return "This cloud file or folder is no longer available. Refresh its parent folder."
        case .rateLimited: return "The provider is receiving too many requests. Wait a moment, then try again."
        case .serviceUnavailable(let status): return "The cloud provider returned HTTP \(status). Try again later."
        case .invalidResponse: return "The cloud provider returned an unexpected response."
        case .unsafeURL: return "The provider returned a link that OpenFiles cannot safely use."
        case .unsupportedDownload: return "This item cannot be downloaded directly. Open it on the provider’s website instead."
        case .destinationExists: return "A file already exists at that destination. Choose a different name or folder."
        case .writePermissionRequired: return "Enable uploads and sync, then reconnect to grant write access."
        case .conflict(let detail): return "Sync conflict: \(detail)"
        case .unsupportedUpload(let detail): return detail
        case .sourceChanged: return "The source changed during transfer. Save it in its editor and try again."
        }
    }
}
