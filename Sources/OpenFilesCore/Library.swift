import Foundation
import NaturalLanguage
import PDFKit

/// Serializes filesystem operations off the UI thread. No cloud services or API credentials.
public actor FileLibrary {
    public let directory: URL
    private var state = LibraryState()
    private var proposals: [MoveProposal] = []
    private var discoveryRoots: [URL] = []
    private let fm = FileManager.default
    private var embedding: NLEmbedding?
    private var loadedEmbedding = false
    public init(directory: URL) { self.directory = directory.canonical }
    private var manifest: URL { directory.appendingPathComponent("library.json") }

    public func load() throws -> LibraryState {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: manifest.path) { state = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: manifest)) }
        return state
    }
    public func current() -> LibraryState { state }
    private func save() throws {
        try JSONEncoder().encode(state).write(to: manifest, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }
    private func model() -> NLEmbedding? {
        if !loadedEmbedding { embedding = NLEmbedding.sentenceEmbedding(for: .english); loadedEmbedding = true }
        return embedding
    }
    /// Search scope is separate from explicit organization targets. Discovery never authorizes moves.
    public func enableDefaultDiscovery(home: URL) {
        let common = ["Downloads", "Documents", "Desktop", "Pictures", "Music", "Movies"].map { home.appendingPathComponent($0, isDirectory: true).canonical }
        discoveryRoots = common.filter { fm.fileExists(atPath: $0.path) } + [home.canonical]
    }
    public func addRoot(_ url: URL) throws {
        let root = url.canonical
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw OpenFilesError.message("Choose a folder.") }
        guard !FileRules.contains(root, directory), !FileRules.contains(directory, root) else { throw OpenFilesError.message("Choose a folder outside OpenFiles app data.") }
        guard !state.roots.contains(where: { FileRules.contains($0, root) || FileRules.contains(root, $0) }) else { throw OpenFilesError.message("This folder overlaps a folder already in your library.") }
        state.roots.append(root)
        do { try save() } catch { state.roots.removeLast(); throw error }
    }
    public func removeRoot(_ root: URL) throws {
        state.roots.removeAll { $0 == root }; state.files.removeAll { $0.root == root }; proposals = []; try save()
    }
    public func setAutoOrganize(_ enabled: Bool) throws { state.autoOrganize = enabled; try save() }
    public func authorized(_ url: URL) throws -> URL {
        let real = url.canonical
        guard state.roots.contains(where: { FileRules.contains($0, real) }), !FileRules.contains(directory, real) else { throw OpenFilesError.message("This file is outside the library.") }
        return real
    }
    private func extractedText(_ url: URL, size: Int64) -> String {
        guard size <= 5 * 1024 * 1024 else { return "" }
        if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
            return (0..<min(pdf.pageCount, 20)).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n").prefix(12000).description
        }
        guard FileRules.textExtensions.contains(url.pathExtension.lowercased()) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8).prefix(12000).description) ?? ""
    }
    public func scan() throws -> ScanReport {
        let old = Dictionary(uniqueKeysWithValues: state.files.map { ($0.url, $0) })
        var files: [FileRecord] = []; var skipped = 0; var seen = Set<String>()
        let embed = model()
        func visit(_ folder: URL, root: URL) {
            guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { skipped += 1; return }
            for url in children.sorted(by: { $0.path < $1.path }) {
                guard files.count < 2000 else { skipped += 1; return }
                guard !["node_modules", "Library", "build", "dist"].contains(url.lastPathComponent), !FileRules.contains(directory, url.canonical) else { continue }
                do {
                    let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey])
                    guard v.isSymbolicLink != true else { continue }
                    let project = v.isDirectory == true && (v.isPackage == true || FileRules.packageExtensions.contains(url.pathExtension.lowercased()))
                    if v.isDirectory == true && !project { visit(url, root: root); continue }
                    guard v.isRegularFile == true || project else { continue }
                    guard seen.insert(url.canonical.path).inserted else { continue }
                    let size = Int64(v.fileSize ?? 0), modified = v.contentModificationDate ?? .distantPast
                    let nameSensitive = FileRules.sensitive(url.lastPathComponent)
                    let text = nameSensitive || project ? "" : extractedText(url, size: size)
                    let sensitive = nameSensitive || FileRules.sensitive(text)
                    let vector: [Double]?
                    if sensitive { vector = nil }
                    else if let prior = old[url], prior.modified == modified, prior.size == size, let cached = prior.vector { vector = cached }
                    else { vector = embed?.vector(for: String("\(url.lastPathComponent)\n\(text)".prefix(4000))) }
                    files.append(FileRecord(id: old[url]?.id ?? UUID(), url: url, root: root, size: size, modified: modified, isProject: project, sensitive: sensitive, vector: vector))
                } catch { skipped += 1 }
            }
        }
        for root in state.roots + discoveryRoots {
            guard files.count < 2000 else { skipped += 1; break }
            visit(root, root: root)
        }
        state.files = files; proposals = []; try save()
        return ScanReport(state: state, skipped: skipped, embeddingsAvailable: embed != nil)
    }
    public func search(_ query: String) -> [FileRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return state.files }
        let vector = model()?.vector(for: String(q.prefix(4000)))
        return state.files.compactMap { file -> (FileRecord, Double)? in
            let lexical = file.name.lowercased().contains(q) ? 2.0 : 0
            let similarity = !file.sensitive ? vector.flatMap { v in file.vector.map { FileRules.cosine(v, $0) } } ?? 0 : 0
            let score = lexical + similarity
            return score > 0.2 ? (file, score) : nil
        }.sorted { $0.1 > $1.1 }.map(\.0)
    }
    public func commit(_ input: URL, message: String) throws -> LibraryState {
        let source = input.canonical
        guard !FileRules.contains(directory, source), !FileRules.contains(source, directory) else { throw OpenFilesError.message("OpenFiles app data cannot be versioned.") }
        try checkSnapshotEligibility(source)
        let version = FileVersion(id: UUID(), source: source, message: message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Saved version" : String(message.prefix(500)), created: Date(), digest: try FileIntegrity.digest(source))
        let folder = directory.appendingPathComponent("Versions/\(version.id.uuidString)")
        let payload = folder.appendingPathComponent(source.lastPathComponent)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            // Full copies preserve opaque binary formats and project packages. Save in the editor first.
            try fm.copyItem(at: source, to: payload)
            guard try FileIntegrity.digest(source) == version.digest, try FileIntegrity.digest(payload) == version.digest else { throw OpenFilesError.message("The file changed during the snapshot. Save in your editor, then retry.") }
            state.versions.insert(version, at: 0)
            do { try save() } catch { state.versions.removeFirst(); throw error }
        } catch { try? fm.removeItem(at: folder); throw error }
        return state
    }
    private func checkSnapshotEligibility(_ url: URL) throws {
        let v = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
        guard v.isSymbolicLink != true else { throw OpenFilesError.message("Projects containing symbolic links are not supported yet.") }
        guard !FileRules.sensitive(url.lastPathComponent) else { throw OpenFilesError.message("Potentially sensitive files are excluded from version history. Use the encrypted vault.") }
        if v.isDirectory == true {
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try checkSnapshotEligibility(child) }
        } else if FileRules.sensitive(extractedText(url, size: Int64(v.fileSize ?? 0))) {
            throw OpenFilesError.message("Potentially sensitive content detected. Use the encrypted vault.")
        }
    }
    public func exportVersion(_ version: FileVersion, into folder: URL) throws -> URL {
        guard state.versions.contains(where: { $0.id == version.id }) else { throw OpenFilesError.message("Version not found.") }
        let source = directory.appendingPathComponent("Versions/\(version.id.uuidString)/\(version.name)")
        guard try FileIntegrity.digest(source) == version.digest else { throw OpenFilesError.message("Snapshot integrity check failed.") }
        let base = version.source.deletingPathExtension().lastPathComponent
        let suffix = version.source.pathExtension.isEmpty ? "" : ".\(version.source.pathExtension)"
        let target = folder.appendingPathComponent("\(base) restored \(version.id.uuidString.prefix(8))\(suffix)")
        // copyItem refuses existing destinations. Restoring never replaces the working file.
        try fm.copyItem(at: source, to: target)
        return target
    }
    public func previewOrganization() throws -> [MoveProposal] {
        proposals = []
        for file in state.files where state.roots.contains(where: { $0.canonical.path == file.root.canonical.path }) && !file.sensitive && !file.isProject && file.url.deletingLastPathComponent().canonical.path == file.root.canonical.path && Date().timeIntervalSince(file.modified) > 10 {
            let source = try authorized(file.url)
            proposals.append(MoveProposal(id: file.id, source: source, destination: file.root.appendingPathComponent("Organized/\(file.category)/\(file.name)"), digest: try FileIntegrity.digest(source)))
        }
        return proposals
    }
    private func createOrganizationDirectory(_ parent: URL) throws {
        guard let root = state.roots.first(where: { FileRules.contains($0, parent) }) else { throw OpenFilesError.message("Invalid destination.") }
        let relative = String(parent.path.dropFirst(root.path.count)).split(separator: "/")
        var current = root
        for component in relative {
            current.appendPathComponent(String(component), isDirectory: true)
            if fm.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isDirectory == true, current.canonical.path == current.standardizedFileURL.path else { throw OpenFilesError.message("Destination contains a symbolic link or non-folder.") }
            } else { try fm.createDirectory(at: current, withIntermediateDirectories: false) }
        }
    }
    public func applyOrganization() throws -> OrganizationReport {
        let plan = proposals; proposals = []; var report = OrganizationReport()
        for move in plan {
            do {
                let source = try authorized(move.source)
                guard try FileIntegrity.digest(source) == move.digest else { throw OpenFilesError.message("Changed since preview; skipped.") }
                // Re-check sensitive content so a changed classification cannot bypass protection.
                try checkSnapshotEligibility(source)
                let parent = move.destination.deletingLastPathComponent()
                try createOrganizationDirectory(parent)
                guard try authorized(parent).path == parent.standardizedFileURL.path else { throw OpenFilesError.message("Destination contains a symbolic link.") }
                try fm.copyItem(at: source, to: move.destination)
                guard try FileIntegrity.digest(source) == move.digest, try FileIntegrity.digest(move.destination) == move.digest else { throw OpenFilesError.message("Changed during move; source retained.") }
                try fm.removeItem(at: source); report.moved += 1
            } catch { report.errors.append("\(move.source.lastPathComponent): \(error.localizedDescription)") }
        }
        _ = try scan(); return report
    }
}
