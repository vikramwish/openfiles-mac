import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct StorageUsage: Equatable, Sendable {
    public let used: Int64?
    public let total: Int64?
    public let available: Int64?
    public init(used: Int64?, total: Int64?, available: Int64? = nil) {
        self.used = used.flatMap { $0 >= 0 ? $0 : nil }
        self.total = total.flatMap { $0 > 0 ? $0 : nil }
        if let available, available >= 0 { self.available = available }
        else if let total = self.total, let used = self.used { self.available = max(0, total - used) }
        else { self.available = nil }
    }
    public var fractionUsed: Double? {
        guard let total, let used else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }
}

extension CloudClient {
    /// Account quota is independent of the folder listing and needs no file downloads.
    public func storageUsage() async throws -> StorageUsage {
        let current = generation
        let endpoint = configuration.provider == .googleDrive
            ? "https://www.googleapis.com/drive/v3/about?fields=storageQuota"
            : "https://graph.microsoft.com/v1.0/me/drive?$select=quota"
        let (data, _) = try await authenticatedSend(URLRequest(url: URL(string: endpoint)!), generation: current)
        try ensureCurrent(current)
        do {
            switch configuration.provider {
            case .googleDrive:
                let quota = try JSONDecoder().decode(GoogleStorage.self, from: data).storageQuota
                func bytes(_ text: String?) throws -> Int64? {
                    guard let text else { return nil }
                    guard let value = Int64(text), value >= 0 else { throw CloudError.invalidResponse }
                    return value
                }
                let used = try bytes(quota.usage), total = try bytes(quota.limit)
                guard used != nil || total != nil else { throw CloudError.invalidResponse }
                return StorageUsage(used: used, total: total)
            case .oneDrive:
                let quota = try JSONDecoder().decode(MicrosoftStorage.self, from: data).quota
                guard [quota.used, quota.total, quota.remaining].compactMap({ $0 }).allSatisfy({ $0 >= 0 }),
                      quota.used != nil || quota.total != nil || quota.remaining != nil else { throw CloudError.invalidResponse }
                return StorageUsage(used: quota.used, total: quota.total, available: quota.remaining)
            }
        } catch let error as CloudError { throw error }
        catch { throw CloudError.invalidResponse }
    }
}

private struct GoogleStorage: Decodable {
    let storageQuota: Quota
    struct Quota: Decodable { let usage: String?; let limit: String? }
}
private struct MicrosoftStorage: Decodable {
    let quota: Quota
    struct Quota: Decodable { let used: Int64?; let total: Int64?; let remaining: Int64? }
}
