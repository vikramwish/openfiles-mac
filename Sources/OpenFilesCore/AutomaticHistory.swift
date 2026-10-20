import Foundation
import Darwin

public struct ProtectedLocation: Codable, Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public var enabled: Bool
    public var lastChecked: Date?
    public var lastSaved: Date?
    public var issue: String?
}

private struct AutomaticSnapshot: Codable, Sendable {
    let id: UUID
    let source: URL
    let bytes: Int64
    let created: Date
}

public struct AutomaticHistoryState: Codable, Sendable {
    public var enabled = true
    public var locations: [ProtectedLocation] = []
    fileprivate var snapshots: [AutomaticSnapshot] = []
    fileprivate var pendingDeletionIDs = Set<UUID>()
    public var storedBytes: Int64 { snapshots.reduce(0) { $0 + $1.bytes } }
    public var savedCount: Int { snapshots.count }
    public init() {}
}

public struct AutomaticHistoryLimits: Sendable {
    public let versionsPerLocation: Int
    public let totalBytes: Int64
    public let locationBytes: Int64
    public let locations: Int
    public let entriesPerLocation: Int
    public let quietSeconds: TimeInterval
    public init(versionsPerLocation: Int = 20, totalBytes: Int64 = 1_000_000_000,
                locationBytes: Int64 = 100_000_000, locations: Int = 20,
                entriesPerLocation: Int = 2_000, quietSeconds: TimeInterval = 2) {
        self.versionsPerLocation = max(1, versionsPerLocation)
        self.totalBytes = max(1, totalBytes); self.locationBytes = max(1, locationBytes)
        self.locations = max(1, locations); self.entriesPerLocation = max(1, entriesPerLocation)
        self.quietSeconds = max(0, quietSeconds)
    }
}

/// Explicitly selected locations only. All filesystem work runs on this actor or FileLibrary.
/// A folder is one complete snapshot; exclusions reject the whole folder rather than losing pieces.
public actor AutomaticHistory {
    private let library: FileLibrary
    private let directory: URL
    private let limits: AutomaticHistoryLimits
    private var state = AutomaticHistoryState()
    private var loaded = false
    private var checking = false
    private let fm = FileManager.default
    private var manifest: URL { directory.appendingPathComponent("automatic-history.json") }

    public init(library: FileLibrary, directory: URL, limits: AutomaticHistoryLimits = .init()) {
        self.library = library; self.directory = directory.canonical; self.limits = limits
    }
    @discardableResult
    public func load() throws -> AutomaticHistoryState {
        if !loaded {
            if fm.fileExists(atPath: manifest.path) {
                state = try JSONDecoder().decode(AutomaticHistoryState.self, from: Data(contentsOf: manifest))
            }
            loaded = true
        }
        return state
    }
    public func current() -> AutomaticHistoryState { state }
    private func save() throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: manifest, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }
    @discardableResult
    public func add(_ urls: [URL]) throws -> AutomaticHistoryState {
        _ = try load()
        var additions: [ProtectedLocation] = []
        for input in urls {
            guard input.isFileURL else { throw OpenFilesError.message("Choose a local file or folder.") }
            guard try input.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw OpenFilesError.message("Choose the original file or folder, not a symbolic link.")
            }
            let url = input.canonical
            try validateLocation(url)
            if state.locations.contains(where: { $0.url == url }) || additions.contains(where: { $0.url == url }) { continue }
            guard !state.locations.contains(where: { FileRules.contains($0.url, url) || FileRules.contains(url, $0.url) }),
                  !additions.contains(where: { FileRules.contains($0.url, url) || FileRules.contains(url, $0.url) }) else {
                throw OpenFilesError.message("This selection overlaps a location already protected. Choose the file or its containing folder.")
            }
            additions.append(ProtectedLocation(id: UUID(), url: url, enabled: true))
        }
        guard state.locations.count + additions.count <= limits.locations else {
            throw OpenFilesError.message("Protect up to \(limits.locations) files or small folders at a time.")
        }
        let old = state
        state.locations.append(contentsOf: additions)
        do { try save() } catch { state = old; throw error }
        return state
    }
    @discardableResult
    public func setEnabled(_ enabled: Bool, locationID: UUID? = nil) throws -> AutomaticHistoryState {
        _ = try load(); let old = state
        if let locationID {
            guard let i = state.locations.firstIndex(where: { $0.id == locationID }) else { return state }
            state.locations[i].enabled = enabled
        } else { state.enabled = enabled }
        do { try save() } catch { state = old; throw error }
        return state
    }
    /// Removing a selection stops future checks. Previously saved versions remain recoverable.
    @discardableResult
    public func remove(_ id: UUID) throws -> AutomaticHistoryState {
        _ = try load(); let old = state
        state.locations.removeAll { $0.id == id }
        do { try save() } catch { state = old; throw error }
        return state
    }
    private func validateLocation(_ url: URL) throws {
        guard url == url.canonical else { throw OpenFilesError.message("The selected path now points to a symbolic link. Choose its original location again.") }
        guard !FileRules.contains(directory, url), !FileRules.contains(url, directory) else {
            throw OpenFilesError.message("Choose a location outside OpenFiles app data.")
        }
        guard !url.pathComponents.contains(where: { $0.hasPrefix(".") || Self.excludedFolders.contains($0.lowercased()) }) else {
            throw OpenFilesError.message("Hidden, dependency, and generated folders are excluded from automatic history.")
        }
        guard !FileRules.sensitive(url.lastPathComponent) else {
            throw OpenFilesError.message("Potentially sensitive files are excluded from history. Use the private vault.")
        }
    }
    private static let excludedFolders: Set<String> = ["node_modules", "vendor", "deriveddata", "build", "dist", "__pycache__"]
    fileprivate static func measure(_ url: URL, limits: AutomaticHistoryLimits) throws -> (bytes: Int64, modified: Date) {
        var bytes: Int64 = 0, entries = 0, newest = Date.distantPast
        func walk(_ item: URL) throws {
            entries += 1
            guard entries <= limits.entriesPerLocation else { throw OpenFilesError.message("This folder has too many items. Choose a smaller folder (up to \(limits.entriesPerLocation) items).") }
            var info = stat()
            guard lstat(item.path, &info) == 0 else { throw OpenFilesError.message("Cannot read this location. Check that it is still available on this Mac.") }
            let cloud = try item.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            guard (info.st_flags & UInt32(SF_DATALESS)) == 0, !item.lastPathComponent.hasSuffix(".icloud"),
                  !(cloud.isUbiquitousItem == true && cloud.ubiquitousItemDownloadingStatus != .current && cloud.ubiquitousItemDownloadingStatus != .downloaded) else {
                throw OpenFilesError.message("Download \(item.lastPathComponent) to this Mac before protecting it.")
            }
            let v = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard v.isSymbolicLink != true else { throw OpenFilesError.message("Folders containing symbolic links cannot be protected yet.") }
            guard !item.lastPathComponent.hasPrefix("."), !Self.excludedFolders.contains(item.lastPathComponent.lowercased()) else {
                throw OpenFilesError.message("This folder contains hidden or generated items. Choose a smaller document folder.")
            }
            newest = max(newest, v.contentModificationDate ?? .distantPast)
            if v.isDirectory == true {
                for child in try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) { try walk(child) }
            } else {
                guard v.isRegularFile == true else { throw OpenFilesError.message("Only regular files and document folders can be protected.") }
                let size = Int64(v.fileSize ?? 0)
                guard size <= limits.locationBytes - bytes else { throw OpenFilesError.message("This selection exceeds \(ByteCountFormatter.string(fromByteCount: limits.locationBytes, countStyle: .file)). Choose a smaller file or folder.") }
                bytes += size
            }
        }
        try walk(url)
        return (bytes, newest)
    }
    /// Only automatic receipts are candidates; retain the newest version of every other source.
    private func retentionPlan(for source: URL, adding bytes: Int64) throws -> Set<UUID> {
        var remaining = state.snapshots.sorted { $0.created > $1.created }
        var remove = Set(remaining.filter { $0.source == source }.dropFirst(limits.versionsPerLocation - 1).map(\.id))
        remaining.removeAll { remove.contains($0.id) }
        var used = remaining.reduce(bytes) { $0 + $1.bytes }
        let newestOther = Set(Dictionary(grouping: remaining.filter { $0.source != source }, by: \.source).values.compactMap { $0.first?.id })
        for item in remaining.reversed() where used > limits.totalBytes && !newestOther.contains(item.id) {
            remove.insert(item.id); used -= item.bytes
        }
        guard used <= limits.totalBytes else {
            throw OpenFilesError.message("Automatic history storage is full. Existing versions are safe; choose a smaller selection.")
        }
        return remove
    }
    @discardableResult
    public func checkNow() async throws -> AutomaticHistoryState {
        _ = try load()
        guard state.enabled, !checking else { return state }
        checking = true; defer { checking = false }
        // Retry interrupted cleanup even when every protected file is unchanged.
        if !state.pendingDeletionIDs.isEmpty {
            try await library.pruneAutomaticHistory(state.pendingDeletionIDs)
            state.snapshots.removeAll { state.pendingDeletionIDs.contains($0.id) }
            state.pendingDeletionIDs.removeAll()
            try save()
        }
        // Iterate stable IDs: a picker action may change selections while awaiting FileLibrary.
        let ids = state.locations.filter(\.enabled).map(\.id)
        for id in ids {
            guard state.enabled, let index = state.locations.firstIndex(where: { $0.id == id && $0.enabled }) else { continue }
            let source = state.locations[index].url
            var saved: Date?, issue: String?
            do {
                try validateLocation(source)
                let exclusions = await library.current().indexSettings?.excludedFolders ?? []
                guard !exclusions.contains(where: { FileRules.contains($0.canonical, source) || FileRules.contains(source, $0.canonical) }) else {
                    throw OpenFilesError.message("This selection includes a folder excluded in indexing settings. Choose an included document folder.")
                }
                let measurement = try Self.measure(source, limits: limits)
                guard Date().timeIntervalSince(measurement.modified) >= limits.quietSeconds else {
                    throw OpenFilesError.message("Waiting for the file to finish saving. It will be checked again shortly.")
                }
                let digest = try FileIntegrity.digest(source)
                let latest = await library.versions(for: source).first
                if latest?.digest == digest { saved = latest?.created }
                else {
                    _ = try retentionPlan(for: source, adding: measurement.bytes)
                    guard state.enabled, state.locations.contains(where: { $0.id == id && $0.enabled }) else { continue }
                    if let captured = try await library.captureAutomaticHistory(source, expectedDigest: digest, limits: limits) {
                        let version = captured.version
                        let remove: Set<UUID>
                        do { remove = try retentionPlan(for: source, adding: captured.bytes) }
                        catch { try await library.pruneAutomaticHistory([version.id]); throw error }
                        state.snapshots.append(AutomaticSnapshot(id: version.id, source: source, bytes: captured.bytes, created: version.created))
                        state.pendingDeletionIDs.formUnion(remove)
                        // Record ownership before pruning. A persistence failure keeps every existing version.
                        try save()
                        saved = version.created
                        try await library.pruneAutomaticHistory(remove)
                        state.snapshots.removeAll { remove.contains($0.id) }
                        state.pendingDeletionIDs.subtract(remove)
                    }
                }
            } catch { issue = error.localizedDescription }
            if let index = state.locations.firstIndex(where: { $0.id == id }) {
                state.locations[index].lastChecked = Date()
                if let saved { state.locations[index].lastSaved = saved }
                state.locations[index].issue = issue
            }
        }
        try save()
        return state
    }
}

extension FileLibrary {
    private static let automaticHistoryMessage = "Automatically saved version"
    /// Digest comparison and capture serialize with manual history operations on FileLibrary.
    fileprivate func captureAutomaticHistory(_ source: URL, expectedDigest: String, limits: AutomaticHistoryLimits) throws -> (version: FileVersion, bytes: Int64)? {
        _ = try AutomaticHistory.measure(source, limits: limits)
        guard try FileIntegrity.digest(source) == expectedDigest else { throw OpenFilesError.message("The file changed while checking it. It will be checked again shortly.") }
        if versions(for: source).first?.digest == expectedDigest { return nil }
        let version = try captureVersion(source: source, contents: source, message: Self.automaticHistoryMessage)
        do {
            guard version.digest == expectedDigest else {
                throw OpenFilesError.message("The file changed during its snapshot. It will be checked again shortly.")
            }
            // Account for the immutable payload, not an earlier source-size estimate.
            let payload = directory.appendingPathComponent("Versions/\(version.id.uuidString)/\(version.name)")
            let actual = try AutomaticHistory.measure(payload, limits: limits)
            return (version, actual.bytes)
        } catch {
            try pruneAutomaticHistory([version.id])
            throw error
        }
    }
    /// Persist the manifest first: interruption may leave an unused payload, never a broken retained version.
    fileprivate func pruneAutomaticHistory(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        guard state.versions.filter({ ids.contains($0.id) }).allSatisfy({ $0.message == Self.automaticHistoryMessage }) else {
            throw OpenFilesError.message("Automatic history cannot remove a manually saved version.")
        }
        let previous = state.versions
        state.versions.removeAll { ids.contains($0.id) }
        do { try save() } catch { state.versions = previous; throw error }
        for id in ids {
            let path = directory.appendingPathComponent("Versions/\(id.uuidString)")
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
    }
}
