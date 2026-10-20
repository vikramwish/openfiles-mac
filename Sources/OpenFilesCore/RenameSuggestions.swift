import Foundation

public struct RenameSuggestion: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    /// Cosine similarity, not a probability.
    public let similarity: Double
}

public struct RenamePreview: Identifiable, Sendable {
    public let id: UUID
    public let source: URL
    public let suggestions: [RenameSuggestion]
    public let model: String
    public var modified: Date { stamp.modified }
    let stamp: FileStamp
    let digest: String
}

public struct RenameResult: Sendable {
    public let destination: URL
    public let indexWarning: String?
}

/// Embeddings rank phrases taken from the document; they do not generate text.
public enum RenameNames {
    public static func candidates(from text: String, extension ext: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ".!?")))
            .prefix(40).compactMap { line -> String? in
                let words = line.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
                guard words.count >= 2 else { return nil }
                var stem = String(words.prefix(8).joined(separator: " ").prefix(80))
                while stem.utf8.count > 200 { stem.removeLast() }
                let name = stem + (ext.isEmpty ? "" : "." + ext)
                guard !FileRules.sensitive(name), seen.insert(name.lowercased()).inserted else { return nil }
                return name
            }.prefix(12).map { $0 }
    }

    public static func validate(_ name: String, source: URL) throws {
        guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.hasPrefix("."), !name.hasSuffix("."), name.utf8.count <= 240,
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              !name.contains("/"), !name.contains(":"), !name.contains("\\"),
              URL(fileURLWithPath: name).pathExtension == source.pathExtension else {
            throw OpenFilesError.message("Use a filename without path separators and keep the original extension.")
        }
        guard name.caseInsensitiveCompare(source.lastPathComponent) != .orderedSame else {
            throw OpenFilesError.message("Choose a different filename.")
        }
    }
}

extension FileLibrary {
    /// Analyze only the selected local file. Cloud copies must first be downloaded or synced.
    public func previewRename(_ url: URL) async throws -> RenamePreview {
        let preview = try await makeRenamePreview(url)
        if renamePreviews.count >= 16 { renamePreviews.removeAll() }
        renamePreviews[preview.id] = preview
        return preview
    }

    func makeRenamePreview(_ url: URL) async throws -> RenamePreview {
        guard url.isFileURL else { throw OpenFilesError.message("Choose a file on this Mac.") }
        let source = url.deletingLastPathComponent().canonical.appendingPathComponent(url.lastPathComponent)
        try checkRenameEligibility(source)
        let stamp = try FileStamp.read(source)
        guard stamp.size <= 5 * 1024 * 1024 else { throw OpenFilesError.message("Name suggestions support downloaded files up to 5 MB.") }
        let extracted = try IndexText.extract(source, size: stamp.size)
        let text = IndexText.prepare(extracted.text)
        guard !FileRules.sensitive(extracted.text) else { throw OpenFilesError.message("Potentially sensitive content is excluded from name suggestions.") }
        guard !text.isEmpty, !extracted.detail.hasPrefix("Filename only:") else {
            throw OpenFilesError.message("No readable content was found. Download the file first, or choose a text document, PDF, or readable image.")
        }
        let digest = try FileIntegrity.digest(source)
        let backend = queryBackend, generation = embeddingGeneration
        let candidates = RenameNames.candidates(from: text, extension: source.pathExtension)
            .filter { $0.caseInsensitiveCompare(source.lastPathComponent) != .orderedSame }
        guard !candidates.isEmpty else { throw OpenFilesError.message("No alternative descriptive names were found in this file.") }
        guard let document = await backend.vector(for: text), !document.isEmpty, document.allSatisfy(\.isFinite) else {
            throw OpenFilesError.message("The search model is unavailable. Choose a model in Indexing Activity and try again.")
        }
        var ranked: [RenameSuggestion] = []
        for name in candidates {
            try Task.checkCancellation()
            let phrase = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            if let vector = await backend.queryVector(for: phrase), vector.count == document.count, vector.allSatisfy(\.isFinite) {
                let score = VectorMath.cosine(document, vector)
                if score >= 0.25 { ranked.append(.init(name: name, similarity: score)) }
            }
        }
        try Task.checkCancellation()
        guard generation == embeddingGeneration else { throw OpenFilesError.message("The search model changed. Request name suggestions again.") }
        guard try FileStamp.read(source) == stamp, try FileIntegrity.digest(source) == digest else {
            throw OpenFilesError.message("The file changed during analysis. Request name suggestions again.")
        }
        ranked.sort { $0.similarity == $1.similarity ? $0.name < $1.name : $0.similarity > $1.similarity }
        guard !ranked.isEmpty else { throw OpenFilesError.message("The model found no clear filename match for this content.") }
        let preview = RenamePreview(id: UUID(), source: source, suggestions: Array(ranked.prefix(3)), model: backend.displayName, stamp: stamp, digest: digest)
        return preview
    }

    public func discardRenamePreview(_ id: UUID) { renamePreviews[id] = nil }

    /// A displayed preview and an explicit filename are required. Existing destinations are never replaced.
    public func applyRename(previewID: UUID, name: String) async throws -> RenameResult {
        guard let preview = renamePreviews.removeValue(forKey: previewID) else {
            throw OpenFilesError.message("This name suggestion has expired. Analyze the file again.")
        }
        return try await performRename(preview, name: name)
    }

    func renameDestination(_ preview: RenamePreview, name: String) throws -> URL {
        let source = preview.source
        try RenameNames.validate(name, source: source)
        try checkRenameEligibility(source)
        guard source.deletingLastPathComponent().canonical == source.deletingLastPathComponent(),
              try FileStamp.read(source) == preview.stamp, try FileIntegrity.digest(source) == preview.digest else {
            throw OpenFilesError.message("The file or its folder changed since preview. Analyze it again.")
        }
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        let fm = FileManager.default
        // Check case-insensitively too, so previews behave consistently across APFS volumes.
        let names = try fm.contentsOfDirectory(atPath: source.deletingLastPathComponent().path)
        guard !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw OpenFilesError.message("A file with that name already exists. Choose another name.")
        }
        return destination
    }

    func performRename(_ preview: RenamePreview, name: String) async throws -> RenameResult {
        let destination = try renameDestination(preview, name: name)
        let source = preview.source, fm = FileManager.default
        try Task.checkCancellation()
        try fm.copyItem(at: source, to: destination)
        guard try FileStamp.read(source) == preview.stamp, try FileIntegrity.digest(source) == preview.digest,
              try FileIntegrity.digest(destination) == preview.digest else {
            throw OpenFilesError.message("The file changed during rename. The original was retained; review both copies.")
        }
        try fm.removeItem(at: source)
        do {
            _ = try await synchronizeChanges([source, destination])
            return RenameResult(destination: destination, indexWarning: nil)
        } catch {
            return RenameResult(destination: destination, indexWarning: "Renamed successfully. Refresh the index: \(error.localizedDescription)")
        }
    }

    private func checkRenameEligibility(_ source: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              !source.lastPathComponent.hasPrefix("."), !FileRules.sensitive(source.lastPathComponent),
              !FileRules.contains(directory, source),
              !(state.indexSettings?.excludedFolders ?? []).contains(where: { FileRules.contains($0.canonical, source) }) else {
            throw OpenFilesError.message("Choose a regular, non-sensitive file outside excluded folders.")
        }
    }
}
