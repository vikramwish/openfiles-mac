import Foundation
import CoreServices

public enum ScreenshotSource: String, Sendable { case systemMetadata, photosMetadata, filename }

public struct ScreenshotFileMetadata: Sendable {
    public var isScreenshot: Bool?
    public var created: Date?
    public var lastUsed: Date?
    public var tags: [String]
    public init(isScreenshot: Bool? = nil, created: Date? = nil, lastUsed: Date? = nil, tags: [String] = []) {
        self.isScreenshot = isScreenshot; self.created = created; self.lastUsed = lastUsed; self.tags = tags
    }
}
public protocol ScreenshotMetadataProvider: Sendable {
    func metadata(for url: URL) -> ScreenshotFileMetadata
}
public struct SystemScreenshotMetadata: ScreenshotMetadataProvider {
    public init() {}
    public func metadata(for url: URL) -> ScreenshotFileMetadata {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .tagNamesKey])
        let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL)
        let screenshot = item.flatMap { MDItemCopyAttribute($0, "kMDItemIsScreenCapture" as CFString) } as? NSNumber
        let lastUsed = item.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) } as? Date
        return .init(isScreenshot: screenshot?.boolValue, created: values?.creationDate, lastUsed: lastUsed, tags: values?.tagNames ?? [])
    }
}

public struct ScreenshotSignals: Sendable {
    public var source: ScreenshotSource
    public var created: Date?
    public var modified: Date
    public var lastUsed: Date?
    public var kept: Bool
    public var contentTerms: [String]?
    public var hasNewerRelatedCapture: Bool
    public init(source: ScreenshotSource, created: Date?, modified: Date, lastUsed: Date? = nil, kept: Bool = false, contentTerms: [String]? = nil, hasNewerRelatedCapture: Bool = false) {
        self.source = source; self.created = created; self.modified = modified; self.lastUsed = lastUsed
        self.kept = kept; self.contentTerms = contentTerms; self.hasNewerRelatedCapture = hasNewerRelatedCapture
    }
}
public struct ScreenshotAssessment: Sendable {
    public let score: Int
    public let evidence: String
}

/// Usage history is incomplete. These are review suggestions, never a claim that a capture is unused.
public enum ScreenshotReview {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp"]
    public static func source(for url: URL, metadata: ScreenshotFileMetadata) -> ScreenshotSource? {
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        if metadata.isScreenshot == true { return .systemMetadata }
        if metadata.isScreenshot == false { return nil }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return name.range(of: #"^(screen[ _-]*shot|screen[ _-]*capture)(?:[ _-]|\d|$)"#, options: .regularExpression) != nil ? .filename : nil
    }
    public static func isOldUnkept(_ signals: ScreenshotSignals, now: Date = Date()) -> Bool {
        guard !signals.kept, signals.modified <= now.addingTimeInterval(-90 * 86400),
              let created = signals.created, created <= now.addingTimeInterval(-90 * 86400) else { return false }
        if let lastUsed = signals.lastUsed, lastUsed > now.addingTimeInterval(-60 * 86400) { return false }
        return true
    }
    public static func assess(_ signals: ScreenshotSignals, now: Date = Date()) -> ScreenshotAssessment? {
        guard isOldUnkept(signals, now: now) else { return nil }
        let words = Set((signals.contentTerms ?? []).flatMap(FileSearchQuery.words))
        let important: Set<String> = ["receipt", "invoice", "passport", "boarding", "ticket", "tax", "insurance", "medical", "contract", "warranty", "booking", "certificate", "prescription", "payment", "licence", "license"]
        guard words.isDisjoint(with: important), !FileRules.sensitive(words.sorted().joined(separator: " ")) else { return nil }
        // Without content analysis require six months, rather than treating an unread image as disposable.
        if signals.contentTerms == nil && (signals.created ?? now) > now.addingTimeInterval(-180 * 86400) { return nil }
        var score = signals.source == .filename ? 2 : 3
        var reasons = [signals.source == .filename ? "Screenshot-style filename; classification may be wrong." : "Identified as a screenshot by macOS.", "Created and last changed over 90 days ago."]
        if let lastUsed = signals.lastUsed {
            score += 2
            reasons.append("macOS last-opened date: \(lastUsed.formatted(date: .abbreviated, time: .omitted)); no recent open is recorded.")
        } else { reasons.append("Last-viewed history is unavailable; this does not prove it is unused.") }
        if !words.isDisjoint(with: ["error", "failed", "failure", "dialog", "notification", "loading", "retry", "timeout"]) {
            score += 2; reasons.append("Recognized text resembles a temporary error, notification, or loading screen.")
        }
        if signals.hasNewerRelatedCapture { score += 2; reasons.append("A newer related screenshot is available to compare; both may still matter.") }
        if (signals.created ?? now) < now.addingTimeInterval(-365 * 86400) { score += 1 }
        if signals.contentTerms == nil { reasons.append("Image contents were not understood; review carefully.") }
        return ScreenshotAssessment(score: score, evidence: reasons.joined(separator: " "))
    }
    public static func textOverlap(_ a: [String], _ b: [String]) -> Bool {
        let common: Set<String> = ["the", "and", "for", "with", "this", "that", "from", "your", "you", "are"]
        let first = Set(a.flatMap(FileSearchQuery.words)).subtracting(common)
        let second = Set(b.flatMap(FileSearchQuery.words)).subtracting(common)
        guard first.count >= 6, second.count >= 6 else { return false }
        return Double(first.intersection(second).count) / Double(first.union(second).count) >= 0.75
    }
}
