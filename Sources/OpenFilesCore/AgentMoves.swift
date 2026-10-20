import Foundation

/// A move the agent proposes. Nothing happens until previewAgentMoves validates it and the user approves it.
public struct AgentMoveRequest: Sendable {
    public let source: URL
    public let folder: URL
    public let reason: String
    public init(source: URL, folder: URL, reason: String = "") {
        self.source = source; self.folder = folder; self.reason = reason
    }
}

public struct AgentMoveSuggestion: Identifiable, Sendable {
    public let id: UUID
    public let source: URL
    public let destination: URL
    public let reason: String
    let digest: String
    let stamp: FileStamp
}

public struct AgentMovePreview: Identifiable, Sendable {
    public let id: UUID
    public let created: Date
    let roots: [URL]
    public var suggestions: [AgentMoveSuggestion] = []
    public var skipped: [String: Int] = [:]
    init(id: UUID = UUID(), created: Date = Date(), roots: [URL]) {
        self.id = id; self.created = created; self.roots = roots
    }
}

extension FileLibrary {
    /// Validate agent-proposed moves against the same rules as semantic organization. Refused moves are
    /// reported, never guessed: only regular personal files outside protected and excluded locations move.
    public func previewAgentMoves(_ requests: [AgentMoveRequest], home: URL, limit: Int = 24) async throws -> AgentMovePreview {
        agentMovePlan = nil
        let home = home.canonical
        let roots = [home] + state.roots.map(\.canonical)
        let excluded = state.indexSettings?.excludedFolders ?? []
        var result = AgentMovePreview(roots: roots)
        var reserved = Set<String>()
        var folderProtection: [String: Bool] = [:]
        let fm = FileManager.default
        for request in requests.prefix(max(1, limit)) {
            try Task.checkCancellation()
            let source = request.source
            func skip(_ reason: String) { result.skipped[reason, default: 0] += 1 }
            guard let folder = AgentPath.stableFolder(request.folder) else { skip("Untrusted destination"); continue }
            guard roots.contains(where: { FileRules.contains($0, folder) }) else { skip("Destination outside personal folders"); continue }
            guard !FileRules.contains(directory, folder), !FileRules.contains(folder, directory) else { skip("App data location"); continue }
            guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { skip("Not a regular file"); continue }
            if let reason = SemanticOrganizer.exclusion(source, roots: roots, output: folder, appData: directory, excluded: excluded, folderProtection: &folderProtection) {
                skip(reason); continue
            }
            do {
                try checkSnapshotEligibility(source)
                let stamp = try FileStamp.read(source)
                let digest = try FileIntegrity.digest(source)
                guard try FileStamp.read(source) == stamp else { skip("Changed during analysis"); continue }
                var target = folder.appendingPathComponent(source.lastPathComponent)
                var suffix = 2
                while fm.fileExists(atPath: target.path) || reserved.contains(target.path.lowercased()) {
                    let ext = source.pathExtension.isEmpty ? "" : "." + source.pathExtension
                    target = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + " (\(suffix))" + ext)
                    suffix += 1
                }
                reserved.insert(target.path.lowercased())
                result.suggestions.append(AgentMoveSuggestion(id: UUID(), source: source, destination: target, reason: request.reason, digest: digest, stamp: stamp))
            } catch { skip("Unreadable or sensitive content") }
        }
        agentMovePlan = result
        return result
    }

    /// Apply approved moves only. Every guard runs again; a changed file or substituted destination stops that move.
    public func applyAgentMoves(planID: UUID, selected: Set<UUID>) async throws -> OrganizationReport {
        guard let plan = agentMovePlan, plan.id == planID,
              selected.isSubset(of: Set(plan.suggestions.map(\.id))) else {
            throw OpenFilesError.message("This preview has expired. Request suggestions again.")
        }
        agentMovePlan = nil
        var report = OrganizationReport()
        let fm = FileManager.default
        var changed: [URL] = []
        for suggestion in plan.suggestions where selected.contains(suggestion.id) {
            do {
                let source = suggestion.source
                var folderProtection: [String: Bool] = [:]
                guard SemanticOrganizer.exclusion(source, roots: plan.roots, output: suggestion.destination.deletingLastPathComponent(), appData: directory, excluded: state.indexSettings?.excludedFolders ?? [], folderProtection: &folderProtection) == nil else {
                    throw OpenFilesError.message("Source is no longer eligible.")
                }
                guard try FileStamp.read(source) == suggestion.stamp, try FileIntegrity.digest(source) == suggestion.digest else {
                    throw OpenFilesError.message("Changed since preview; skipped.")
                }
                try checkSnapshotEligibility(source)
                try ensureAgentDestinationFolder(suggestion.destination.deletingLastPathComponent(), roots: plan.roots)
                try fm.copyItem(at: source, to: suggestion.destination)
                guard try FileStamp.read(source) == suggestion.stamp,
                      try FileIntegrity.digest(source) == suggestion.digest,
                      try FileIntegrity.digest(suggestion.destination) == suggestion.digest else {
                    throw OpenFilesError.message("Changed during move; the original was retained. Review both copies.")
                }
                try fm.removeItem(at: source)
                changed += [source, suggestion.destination]
                report.moved += 1
            } catch { report.errors.append("\(suggestion.source.path): \(error.localizedDescription)") }
        }
        if !changed.isEmpty {
            do { _ = try await synchronizeChanges(changed) }
            catch { report.errors.append("Files were moved, but the index needs a refresh: \(error.localizedDescription)") }
        }
        return report
    }

    /// Create missing destination components without ever following a substituted symbolic link.
    private func ensureAgentDestinationFolder(_ folder: URL, roots: [URL]) throws {
        guard let root = roots.first(where: { FileRules.contains($0, folder) }) else {
            throw OpenFilesError.message("Invalid destination.")
        }
        let fm = FileManager.default
        var current = root
        for component in folder.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            if fm.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      current.canonical.path == current.standardizedFileURL.path else {
                    throw OpenFilesError.message("Destination contains a link or non-folder.")
                }
            } else {
                try fm.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
    }
}

/// Path hygiene shared by agent move validation: absolute, no traversal, standardized to the index form.
enum AgentPath {
    static func stableFolder(_ raw: URL) -> URL? {
        let path = raw.standardizedFileURL.path
        guard path.hasPrefix("/"), path.utf8.count <= 1024,
              !path.components(separatedBy: "/").contains("..") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
