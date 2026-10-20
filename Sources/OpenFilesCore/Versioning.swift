import Foundation

public struct VersionChange: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let removed: String
    public let added: String
    // Text edits address the baseline. Folder edits address relative file paths.
    let range: Range<Int>?
    let replacement: [String]?
    let contextBefore: [String]
    let contextAfter: [String]
}

public struct VersionReview: Sendable {
    public let source: URL
    public let workingDigest: String
    public let baseID: UUID?
    public let versionID: UUID?
    public let changes: [VersionChange]
    public let kind: Kind
    public enum Kind: Sendable { case text, files, document }
}

extension FileLibrary {
    private func snapshot(_ version: FileVersion) throws -> URL {
        let url = directory.appendingPathComponent("Versions/\(version.id.uuidString)/\(version.name)")
        guard try FileIntegrity.digest(url) == version.digest else { throw OpenFilesError.message("Snapshot integrity check failed.") }
        return url
    }
    @discardableResult
    func captureVersion(source: URL, contents: URL, message: String) throws -> FileVersion {
        guard !FileRules.contains(directory, source), !FileRules.contains(source, directory) else { throw OpenFilesError.message("OpenFiles app data cannot be versioned.") }
        try checkSnapshotEligibility(contents)
        guard !FileRules.sensitive(source.lastPathComponent) else { throw OpenFilesError.message("Potentially sensitive files are excluded from history.") }
        let digest = try FileIntegrity.digest(contents)
        let version = FileVersion(id: UUID(), source: source, message: String(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Saved version" : message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)), created: Date(), digest: digest)
        let folder = directory.appendingPathComponent("Versions/\(version.id.uuidString)")
        let payload = folder.appendingPathComponent(source.lastPathComponent)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try fm.copyItem(at: contents, to: payload)
            guard try FileIntegrity.digest(contents) == digest, try FileIntegrity.digest(payload) == digest else { throw OpenFilesError.message("The file changed during the commit. Wait for the editor to finish saving and retry.") }
            state.versions.insert(version, at: 0)
            do { try save() } catch { state.versions.removeFirst(); throw error }
        } catch { try? fm.removeItem(at: folder); throw error }
        return version
    }
    private func reviewSources(_ url: URL, versionID: UUID?) throws -> (URL?, URL, UUID?) {
        let history = versions(for: url)
        if let versionID {
            guard let index = history.firstIndex(where: { $0.id == versionID }) else { throw OpenFilesError.message("Version not found for this file.") }
            let base = index + 1 < history.count ? history[index + 1] : nil
            return (try base.map(snapshot), try snapshot(history[index]), base?.id)
        }
        let base = history.first
        return (try base.map(snapshot), url, base?.id)
    }
    private func textLines(_ url: URL?) throws -> [String]? {
        guard let url else { return [] }
        guard FileRules.textExtensions.subtracting(["rtf"]).contains(url.pathExtension.lowercased()),
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
              let text = String(data: try Data(contentsOf: url), encoding: .utf8), !text.contains("\0") else { return nil }
        let lines = text.components(separatedBy: "\n")
        return lines.count <= 10_000 ? lines : nil
    }
    private func fileMap(_ folder: URL?) throws -> [String: URL] {
        guard let folder else { return [:] }
        var result: [String: URL] = [:]
        func walk(_ parent: URL, prefix: String) throws {
            for child in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw OpenFilesError.message("Symbolic links cannot be versioned.") }
                let path = prefix + child.lastPathComponent
                if values.isDirectory == true { try walk(child, prefix: path + "/") }
                else { result[path] = child }
            }
        }
        try walk(folder, prefix: "")
        return result
    }
    public func reviewChanges(_ input: URL, versionID: UUID? = nil) throws -> VersionReview {
        let url = input.canonical
        guard !FileRules.contains(directory, url), !FileRules.contains(url, directory) else { throw OpenFilesError.message("OpenFiles app data cannot be versioned.") }
        let workingDigest = try FileIntegrity.digest(url)
        let (base, target, baseID) = try reviewSources(url, versionID: versionID)
        let isFolder = try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let baseFolder = try base?.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        var changes: [VersionChange] = []
        let kind: VersionReview.Kind
        if isFolder && (base == nil || baseFolder) {
            kind = .files
            let before = try fileMap(base), after = try fileMap(target)
            for path in Set(before.keys).union(after.keys).sorted() {
                if try before[path].map(FileIntegrity.digest) != after[path].map(FileIntegrity.digest) {
                    changes.append(VersionChange(id: path, title: path, removed: before[path] == nil ? "" : "Previous file", added: after[path] == nil ? "" : "Updated file", range: nil, replacement: nil, contextBefore: [], contextAfter: []))
                }
            }
            // Empty folders and directory-only changes are captured as a whole project.
            if try changes.isEmpty && base.map(FileIntegrity.digest) != FileIntegrity.digest(target) {
                kindFallback(&changes)
            }
        } else if !isFolder, !baseFolder, let old = try textLines(base), let new = try textLines(target) {
            kind = .text
            var removed = Set<Int>(), inserted = Set<Int>()
            for edit in new.difference(from: old) {
                switch edit { case .remove(let offset, _, _): removed.insert(offset); case .insert(let offset, _, _): inserted.insert(offset) }
            }
            var i = 0, j = 0
            while i < old.count || j < new.count {
                if removed.contains(i) || inserted.contains(j) {
                    let start = i, newStart = j
                    while i < old.count && removed.contains(i) { i += 1 }
                    while j < new.count && inserted.contains(j) { j += 1 }
                    changes.append(VersionChange(id: "lines:\(start):\(i):\(newStart):\(j)", title: "Line \(start + 1) · −\(i - start) +\(j - newStart)", removed: old[start..<i].joined(separator: "\n"), added: new[newStart..<j].joined(separator: "\n"), range: start..<i, replacement: Array(new[newStart..<j]), contextBefore: Array(old[max(0, start - 2)..<start]), contextAfter: Array(old[i..<min(old.count, i + 2)])))
                } else { i += 1; j += 1 }
            }
        } else {
            kind = .document
            if try base.map(FileIntegrity.digest) != FileIntegrity.digest(target) { kindFallback(&changes) }
        }
        guard try FileIntegrity.digest(url) == workingDigest else { throw OpenFilesError.message("The file is being saved. Changes will refresh shortly.") }
        return VersionReview(source: url, workingDigest: workingDigest, baseID: baseID, versionID: versionID, changes: changes, kind: changes.first?.id == "document" ? .document : kind)
    }
    private func kindFallback(_ changes: inout [VersionChange]) {
        changes = [VersionChange(id: "document", title: "Complete document", removed: "Previous version", added: "Saved document", range: nil, replacement: nil, contextBefore: [], contextAfter: [])]
    }
    private func validated(_ review: VersionReview, selected: Set<String>) throws -> VersionReview {
        let fresh = try reviewChanges(review.source, versionID: review.versionID)
        guard fresh.workingDigest == review.workingDigest, fresh.baseID == review.baseID, fresh.changes == review.changes else { throw OpenFilesError.message("Changes have moved since this review. Refresh and select them again.") }
        guard !selected.isEmpty, selected.isSubset(of: Set(fresh.changes.map(\.id))) else { throw OpenFilesError.message("Select at least one change.") }
        return fresh
    }
    private func workspace() throws -> URL {
        let path = directory.appendingPathComponent("VersionWork/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return path
    }
    public func commitChanges(_ review: VersionReview, selected: Set<String>, message: String) throws -> LibraryState {
        guard review.versionID == nil else { throw OpenFilesError.message("Use cherry-pick for an earlier commit.") }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OpenFilesError.message("Describe these changes before committing.") }
        let fresh = try validated(review, selected: selected)
        let (base, target, _) = try reviewSources(fresh.source, versionID: nil)
        let work = try workspace(); defer { try? FileManager.default.removeItem(at: work) }
        let staged = work.appendingPathComponent(fresh.source.lastPathComponent)
        try prepare(fresh, selected: selected, base: base, target: target, destination: staged, cherryPick: false)
        guard try FileIntegrity.digest(fresh.source) == fresh.workingDigest else { throw OpenFilesError.message("The file changed while committing. Review the latest changes and retry.") }
        try captureVersion(source: fresh.source, contents: staged, message: message)
        return state
    }
    private func prepare(_ review: VersionReview, selected: Set<String>, base: URL?, target: URL, destination: URL, cherryPick: Bool) throws {
        let fm = FileManager.default
        if !cherryPick && selected == Set(review.changes.map(\.id)) {
            try fm.copyItem(at: target, to: destination)
            return
        }
        switch review.kind {
        case .text:
            guard var lines = try textLines(cherryPick ? review.source : base), let old = try textLines(base) else { throw OpenFilesError.message("Text format changed. Refresh the review.") }
            var edits: [(Range<Int>, [String])] = []
            for change in review.changes where selected.contains(change.id) {
                guard let range = change.range, let replacement = change.replacement else { continue }
                if cherryPick {
                    let needle = change.contextBefore + Array(old[range]) + change.contextAfter
                    let matches = (0...max(0, lines.count - needle.count)).filter { offset in
                        offset + needle.count <= lines.count && Array(lines[offset..<(offset + needle.count)]) == needle
                    }
                    guard matches.count == 1 else { throw OpenFilesError.message("Conflict at \(change.title). The surrounding text has changed. No changes were applied.") }
                    let start = matches[0] + change.contextBefore.count
                    edits.append((start..<(start + range.count), replacement))
                } else { edits.append((range, replacement)) }
            }
            let ordered = edits.sorted { $0.0.lowerBound > $1.0.lowerBound }
            for index in ordered.indices {
                if index > 0 && ordered[index].0.upperBound > ordered[index - 1].0.lowerBound {
                    throw OpenFilesError.message("Selected changes overlap. No changes were applied.")
                }
                lines.replaceSubrange(ordered[index].0, with: ordered[index].1)
            }
            try Data(lines.joined(separator: "\n").utf8).write(to: destination, options: .atomic)
        case .files:
            let initial = cherryPick ? review.source : base
            if let initial { try fm.copyItem(at: initial, to: destination) }
            else { try fm.createDirectory(at: destination, withIntermediateDirectories: true) }
            let before = try fileMap(base), after = try fileMap(target), current = try fileMap(cherryPick ? review.source : base)
            for change in review.changes where selected.contains(change.id) {
                let path = change.id
                if cherryPick {
                    guard try current[path].map(FileIntegrity.digest) == before[path].map(FileIntegrity.digest) else { throw OpenFilesError.message("Conflict in \(path). No changes were applied.") }
                }
                let output = destination.appendingPathComponent(path)
                if cherryPick, after[path] != nil,
                   (try? output.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    throw OpenFilesError.message("Conflict in \(path): a folder occupies this file’s path. No changes were applied.")
                }
                if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
                if let input = after[path] {
                    try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: input, to: output)
                }
            }
        case .document:
            if cherryPick {
                guard try base.map(FileIntegrity.digest) == FileIntegrity.digest(review.source) else { throw OpenFilesError.message("This document has diverged. Use Restore version to return to the whole document with a recovery snapshot.") }
            }
            try fm.copyItem(at: target, to: destination)
        }
    }
    /// Replacement is coordinated and atomic; current saved work is committed before replacement.
    private func install(_ staged: URL, at source: URL, expected: String, message: String) throws {
        let fm = FileManager.default, digest = try FileIntegrity.digest(staged)
        try checkSnapshotEligibility(source); try checkSnapshotEligibility(staged)
        let sibling = source.deletingLastPathComponent().appendingPathComponent(".openfiles-\(UUID().uuidString)-\(source.lastPathComponent)")
        try fm.copyItem(at: staged, to: sibling)
        defer { try? fm.removeItem(at: sibling) }
        guard try FileIntegrity.digest(sibling) == digest else { throw OpenFilesError.message("Replacement verification failed.") }
        var coordinationError: NSError?, operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: source, options: .forReplacing, error: &coordinationError) { coordinated in
            do {
                guard try FileIntegrity.digest(coordinated) == expected else { throw OpenFilesError.message("The editor saved new changes. Refresh before applying this version.") }
                if versions(for: source).first?.digest != expected { try captureVersion(source: source, contents: coordinated, message: "Recovery before \(message)") }
                // Recheck after backup so an uncoordinated editor cannot silently lose a save during snapshotting.
                guard try FileIntegrity.digest(coordinated) == expected else { throw OpenFilesError.message("The editor saved new changes. Nothing was replaced.") }
                _ = try fm.replaceItemAt(coordinated, withItemAt: sibling)
            } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
        guard try FileIntegrity.digest(source) == digest else { throw OpenFilesError.message("The editor changed the file after applying. Your recovery snapshot is available in history.") }
        try captureVersion(source: source, contents: source, message: message)
    }
    public func cherryPick(_ review: VersionReview, selected: Set<String>, message: String) throws -> LibraryState {
        guard let versionID = review.versionID, let version = state.versions.first(where: { $0.id == versionID }) else { throw OpenFilesError.message("Choose a historical commit first.") }
        let fresh = try validated(review, selected: selected)
        let (base, target, _) = try reviewSources(fresh.source, versionID: versionID)
        let work = try workspace(); defer { try? FileManager.default.removeItem(at: work) }
        let staged = work.appendingPathComponent(fresh.source.lastPathComponent)
        try prepare(fresh, selected: selected, base: base, target: target, destination: staged, cherryPick: true)
        let note = message.trimmingCharacters(in: .whitespacesAndNewlines)
        try install(staged, at: fresh.source, expected: fresh.workingDigest, message: note.isEmpty ? "Cherry-pick: \(version.message)" : note)
        return state
    }
    public func restoreVersion(_ id: UUID, expectedDigest: String) throws -> LibraryState {
        guard let version = state.versions.first(where: { $0.id == id }) else { throw OpenFilesError.message("Version not found.") }
        let payload = try snapshot(version)
        try install(payload, at: version.source, expected: expectedDigest, message: "Restore: \(version.message)")
        return state
    }
}
