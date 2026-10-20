import Foundation
import Darwin

public struct IndexSettings: Codable, Hashable, Sendable {
    public var maxFiles: Int = 2000 // 0 means unlimited. Does not limit browsing or Spotlight.
    public var workers: Int = 2
    public var excludedFolders: [URL] = []
    public var paused: Bool = false
    public init() {}
}

/// Git-style stat cache: ctime + nanosecond mtime + identity catch same-size replacements.
public struct FileStamp: Codable, Hashable, Sendable {
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanos: Int64
    public let changedSeconds: Int64
    public let changedNanos: Int64
    public let device: Int32
    public let inode: UInt64
    public static func read(_ url: URL) throws -> FileStamp {
        var value = stat()
        let code = url.withUnsafeFileSystemRepresentation { pointer in pointer.map { lstat($0, &value) } ?? -1 }
        guard code == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return FileStamp(size: value.st_size, modifiedSeconds: Int64(Int64(value.st_mtimespec.tv_sec)), modifiedNanos: Int64(Int64(value.st_mtimespec.tv_nsec)), changedSeconds: Int64(Int64(value.st_ctimespec.tv_sec)), changedNanos: Int64(Int64(value.st_ctimespec.tv_nsec)), device: value.st_dev, inode: value.st_ino)
    }
    public var modified: Date { Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanos) / 1_000_000_000) }
}

public struct FileIndexMetadata: Codable, Hashable, Sendable {
    public var stamp: FileStamp
    public var engine: String
    public var objectKey: String?
    public var wordUnits: Int
    public var inputCharacters: Int
    public var outcome: String
    public var detail: String
    public var retryable: Bool
}

public struct IndexEvent: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var path: String
    public var outcome: String
    public var detail: String
}

public struct IndexProgress: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case idle, discovering, indexing, paused, completed, cancelled, failed }
    public var phase: Phase = .idle
    public var started: Date?
    public var finished: Date?
    public var discovered = 0
    public var processed = 0
    public var statHits = 0
    public var objectHits = 0
    public var embedded = 0
    public var extracted = 0
    public var tokenized = 0
    public var wordUnits = 0
    public var bytesRead: Int64 = 0
    public var extractionSeconds = 0.0
    public var tokenizationSeconds = 0.0
    public var embeddingSeconds = 0.0
    public var elapsedSeconds = 0.0
    public var activeSeconds = 0.0
    public var workers = 0
    public var modelAvailable = false
    public var engine = "Apple NaturalLanguage · English sentence embedding"
    public var engineID = ""
    public var currentPath = ""
    public var activePaths: [String]?
    public var skipReasons: [String: Int] = [:]
    public var events: [IndexEvent] = []
    public var limitReached = false
    public var limit = 2000
    public var checkpointed = 0
    public var message = "Ready to index"
    public init() {}
    public var fraction: Double? { discovered > 0 && phase != .discovering ? Double(processed) / Double(discovered) : nil }
    public var reused: Int { statHits + objectHits }
    public var filesPerSecond: Double { activeSeconds > 0 ? Double(processed) / activeSeconds : 0 }
    public var skipped: Int { skipReasons.values.reduce(0, +) }
    public var persistedSummary: IndexProgress { var copy = self; copy.currentPath = ""; copy.activePaths = []; copy.events = []; return copy }
}

/// Progress/control are readable without waiting for an inference worker or the library actor.
public final class IndexMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var value = IndexProgress()
    private var publishedAt = Date()
    public init() {}
    public func snapshot() -> IndexProgress {
        lock.lock(); defer { lock.unlock() }
        var current = value
        let delta = Date().timeIntervalSince(publishedAt)
        if current.phase == .discovering || current.phase == .indexing { current.elapsedSeconds += delta; current.activeSeconds += delta }
        else if current.phase == .paused { current.elapsedSeconds += delta }
        return current
    }
    func publish(_ progress: IndexProgress) { lock.lock(); defer { lock.unlock() }; value = progress; publishedAt = Date() }
}

public final class IndexControl: @unchecked Sendable {
    private let lock = NSLock()
    private var pausedValue = false
    private var cancelledValue = false
    private var pauseStart: Date?
    private var accumulatedPause = 0.0
    public init(paused: Bool = false) { pausedValue = paused; if paused { pauseStart = Date() } }
    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return pausedValue }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledValue }
    public var pausedSeconds: Double { lock.lock(); defer { lock.unlock() }; return accumulatedPause + (pauseStart.map { Date().timeIntervalSince($0) } ?? 0) }
    public func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard value != pausedValue else { return }
        pausedValue = value
        if value { pauseStart = Date() } else { accumulatedPause += pauseStart.map { Date().timeIntervalSince($0) } ?? 0; pauseStart = nil }
    }
    public func cancel() { lock.lock(); cancelledValue = true; lock.unlock() }
    func checkpoint() async throws {
        while true {
            try Task.checkCancellation()
            if isCancelled { throw CancellationError() }
            if !isPaused { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
