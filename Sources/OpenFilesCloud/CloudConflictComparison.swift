import Foundation

public struct CloudTextChange: Identifiable, Sendable {
    public enum Kind: Sendable { case removed, added }
    public let id: Int
    public let kind: Kind
    public let line: Int
    public let text: String
}

public struct CloudTextComparison: Sendable {
    public let local: String
    public let cloud: String
    public let changes: [CloudTextChange]
    public static func read(local: URL, cloud: URL) throws -> Self? {
        func text(_ url: URL) throws -> String? {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
            guard data.count <= 1024 * 1024, !data.contains(0), let value = String(data: data, encoding: .utf8), value.components(separatedBy: "\n").count <= 2000 else { return nil }
            return value
        }
        guard let left = try text(local), let right = try text(cloud) else { return nil }
        let difference = right.components(separatedBy: "\n").difference(from: left.components(separatedBy: "\n"))
        let changes = difference.enumerated().map { index, change -> CloudTextChange in
            switch change {
            case .remove(let offset, let element, _): return .init(id: index, kind: .removed, line: offset + 1, text: element)
            case .insert(let offset, let element, _): return .init(id: index, kind: .added, line: offset + 1, text: element)
            }
        }
        return Self(local: left, cloud: right, changes: changes)
    }
}

public struct CloudConflictComparison: Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let localURL: URL
    public let cloudURL: URL
    public let localSize: Int64
    public let localModified: Date?
    public let remote: CloudItem
    public let text: CloudTextComparison?
}

public enum CloudConflictChoice: Sendable { case keepLocal, keepCloud }
