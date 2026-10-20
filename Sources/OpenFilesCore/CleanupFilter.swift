import Foundation

/// Narrows an existing review without widening its filesystem permissions or changing its evidence.
public struct CleanupFilter: Equatable, Sendable {
    public var minimumBytes: Int64 = 0
    public var olderThanDays: Int = 0
    public var kind: CleanupKind?
    public init(minimumBytes: Int64 = 0, olderThanDays: Int = 0, kind: CleanupKind? = nil) {
        self.minimumBytes = minimumBytes; self.olderThanDays = olderThanDays; self.kind = kind
    }
    public func matches(_ file: CleanupFile, now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Double(min(36_500, max(0, olderThanDays))) * 86_400)
        return file.bytes >= max(0, minimumBytes) && (olderThanDays <= 0 || file.modified <= cutoff)
            && (kind == nil || file.kind == kind)
    }
    public func apply(to review: CleanupReview, now: Date = Date()) -> FilteredCleanupReview {
        let groups = review.duplicates.filter { $0.files.contains { matches($0, now: now) } }
        let suggestions = review.suggestions.filter { matches($0, now: now) }
        let eligible = (groups.flatMap(\.files) + suggestions).filter { matches($0, now: now) }
        var potential = suggestions.reduce(Int64(0)) { $0 + $1.bytes }
        for group in groups {
            let matching = group.files.filter { matches($0, now: now) }
            potential += matching.reduce(Int64(0)) { $0 + $1.bytes }
            // Even if every copy matches, one must remain. Copies outside the filter can be keepers.
            if matching.count == group.files.count { potential -= matching.map(\.bytes).min() ?? 0 }
        }
        return FilteredCleanupReview(duplicates: groups, suggestions: suggestions,
                                    selectableIDs: Set(eligible.map(\.id)), potentialBytes: potential)
    }
}

public struct FilteredCleanupReview: Sendable {
    public let duplicates: [DuplicateSet]
    public let suggestions: [CleanupFile]
    public let selectableIDs: Set<UUID>
    /// Logical file sizes, with one retained copy per duplicate group. Not immediate free disk space.
    public let potentialBytes: Int64
}
