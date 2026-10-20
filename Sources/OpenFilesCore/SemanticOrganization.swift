import Foundation

public struct OrganizationTopic: Identifiable, Sendable {
    public let id: String
    public let description: String
    public static let defaults: [Self] = [
        .init(id: "Work", description: "Work business meeting notes, client proposals, product plans, marketing strategy and professional presentations."),
        .init(id: "Study", description: "Education study materials, course lectures, homework assignments, academic research and scientific papers."),
        .init(id: "Travel", description: "Travel vacation itinerary, flights, hotel bookings, sightseeing destinations and holiday planning."),
        .init(id: "Home", description: "Home household maintenance, appliance instructions, renovation plans, furniture and gardening."),
        .init(id: "Creative", description: "Creative art design inspiration, photography, illustrations, music compositions, film scripts and stories."),
        .init(id: "Purchases", description: "Shopping purchase receipts, order confirmations, product warranties and delivery information."),
        .init(id: "Events", description: "Events invitations, concerts, conferences, celebrations, tickets and social gatherings."),
        .init(id: "Cooking", description: "Cooking recipes, ingredients, meal preparation, baking and food menus.")
    ]
}

public struct OrganizationSuggestion: Identifiable, Sendable {
    public let id: UUID
    public let source: URL
    public let destination: URL
    public let topic: String
    /// Cosine similarity, not a calibrated probability.
    public let similarity: Double
    public let margin: Double
    public let evidence: String
    let digest: String
    let stamp: FileStamp
}

public struct OrganizationPreview: Identifiable, Sendable {
    public var id: UUID
    public let created: Date
    public let destination: URL
    public var indexedFiles: Int
    public var suggestions: [OrganizationSuggestion] = []
    public var skipped: [String: Int] = [:]
    public var deferred: Int = 0
    public var modelAvailable = false
}

public enum SemanticOrganizer {
    /// Ambiguous matches stay in place. Thresholds are conservative heuristics, not certainty.
    public static func classify(_ vector: [Double], topics: [String: [Double]]) -> (topic: String, similarity: Double, margin: Double)? {
        let ranked = topics.compactMap { name, prototype -> (String, Double)? in
            guard vector.count == prototype.count, !vector.isEmpty,
                  vector.allSatisfy(\.isFinite), prototype.allSatisfy(\.isFinite) else { return nil }
            return (name, VectorMath.cosine(vector, prototype))
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        guard ranked.count >= 2, let best = ranked.first else { return nil }
        let margin = best.1 - ranked[1].1
        guard best.1 >= 0.45, margin >= 0.06 else { return nil }
        return (best.0, best.1, margin)
    }

    static func exclusion(_ source: URL, roots: [URL], output: URL, appData: URL, excluded: [URL], folderProtection: inout [String: Bool]) -> String? {
        let fm = FileManager.default
        if FileRules.photoLibrary(containing: source.canonical) != nil { return "Photos library managed by Photos" }
        guard let root = roots.filter({ FileRules.contains($0, source) }).min(by: { $0.path.count < $1.path.count }) else { return "Outside personal file scope" }
        if FileRules.contains(output, source) { return "Already organized" }
        if FileRules.contains(appData, source) || excluded.contains(where: { FileRules.contains($0, source) }) { return "Excluded location" }
        guard hasExpectedCanonicalPath(source) else { return "Symbolic link" }
        let protected = Set(["Library", "Applications", "System", "node_modules", "vendor", "build", "dist", "DerivedData", "venv", ".venv", "env", "__pycache__", "usr", "bin", "sbin", "etc", "dev", "private", "var", "opt"])
        let markers = [".git", ".hg", "Package.swift", "package.json", "Cargo.toml", "pyproject.toml", "pyvenv.cfg", "CMakeLists.txt", "go.mod", "pom.xml", "build.gradle"]
        var parent = source.deletingLastPathComponent()
        while FileRules.contains(root, parent) {
            let protectedFolder: Bool
            if let cached = folderProtection[parent.path] { protectedFolder = cached }
            else {
                protectedFolder = parent.lastPathComponent.hasPrefix(".") || protected.contains(parent.lastPathComponent) ||
                    FileRules.packageExtensions.contains(parent.pathExtension.lowercased()) ||
                    markers.contains(where: { fm.fileExists(atPath: parent.appendingPathComponent($0).path) })
                folderProtection[parent.path] = protectedFolder
            }
            if protectedFolder { return "App, system or project files" }
            if parent == root { break }
            parent.deleteLastPathComponent()
        }
        if source.lastPathComponent.hasPrefix(".") { return "Hidden file" }
        return nil
    }
}

extension FileLibrary {
    /// Explicit planning analyzes existing content vectors. Merely indexing never creates a move plan.
    public func previewSemanticOrganization(home: URL, limit: Int = 200) async throws -> OrganizationPreview {
        semanticOrganizationPlan = nil
        let generation = UUID(); semanticOrganizationGeneration = generation
        let home = home.canonical
        let output = home.appendingPathComponent("Organized", isDirectory: true)
        let roots = MacScanScopes.reduce([home] + indexScopes())
        let snapshot = state.files
        var result = OrganizationPreview(id: UUID(), created: Date(), destination: output, indexedFiles: snapshot.count)
        var folderProtection: [String: Bool] = [:]
        let eligible = snapshot.filter { file in
            !file.sensitive && !file.isProject && !FileRules.sensitive(file.name) &&
            SemanticOrganizer.exclusion(file.url, roots: roots, output: output, appData: directory, excluded: state.indexSettings?.excludedFolders ?? [], folderProtection: &folderProtection) == nil
        }
        let references = snapshot.filter { FileRules.contains(output, $0.url) && !$0.sensitive && !$0.isProject }
        let contexts = OrganizationContext.dynamicSuggestions(for: Array(eligible.prefix(10_000)) + references.prefix(5_000), roots: [home] + roots)
        result.deferred = max(0, eligible.count - 10_000)
        try Task.checkCancellation()
        guard semanticOrganizationGeneration == generation else { throw CancellationError() }
        result.modelAvailable = !contexts.isEmpty || snapshot.contains { $0.imageContent != nil || !($0.searchTerms ?? []).isEmpty }
        var reserved = Set<String>()
        for file in snapshot.sorted(by: { $0.url.path < $1.url.path }) {
            try Task.checkCancellation()
            let source = file.url
            func skip(_ reason: String) { result.skipped[reason, default: 0] += 1 }
            if file.sensitive || FileRules.sensitive(file.name) { skip("Potentially sensitive"); continue }
            if file.isProject { skip("App, system or project files"); continue }
            guard let meta = file.indexMetadata,
                  file.imageContent != nil || !meta.detail.hasPrefix("Filename only:") else { skip("Indexed content not available"); continue }
            if let reason = SemanticOrganizer.exclusion(source, roots: roots, output: output, appData: directory, excluded: state.indexSettings?.excludedFolders ?? [], folderProtection: &folderProtection) { skip(reason); continue }
            guard let context = contexts[file.id], !context.folders.isEmpty else { skip("Uncertain context match"); continue }
            if result.suggestions.count >= max(1, limit) { result.deferred += 1; continue }
            do {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { skip("Not a regular file"); continue }
                let stamp = try FileStamp.read(source)
                guard stamp == meta.stamp, Date().timeIntervalSince(stamp.modified) > 10 else { skip("Changed or recently edited; reindex needed"); continue }
                try checkSnapshotEligibility(source)
                let digest = try FileIntegrity.digest(source)
                guard try FileStamp.read(source) == stamp else { skip("Changed during analysis"); continue }
                let folder = context.folders.reduce(output) { $0.appendingPathComponent($1, isDirectory: true) }
                var target = folder.appendingPathComponent(file.name)
                var suffix = 2
                while FileManager.default.fileExists(atPath: target.path) || reserved.contains(target.path.lowercased()) {
                    let ext = source.pathExtension.isEmpty ? "" : "." + source.pathExtension
                    target = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + " (\(suffix))" + ext); suffix += 1
                }
                reserved.insert(target.path.lowercased())
                result.suggestions.append(.init(id: file.id, source: source, destination: target, topic: context.topic, similarity: 0, margin: 0, evidence: (context.reasons + ["Indexed evidence: " + meta.detail]).joined(separator: "\n"), digest: digest, stamp: stamp))
            } catch { skip("Unreadable or sensitive content") }
        }
        semanticOrganizationPlan = result
        return result
    }

    /// Changes only the in-memory proposal. A fresh plan ID invalidates older windows.
    public func reviseSemanticOrganizationFolder(planID: UUID, suggestionID: UUID, folders: [String]) throws -> OrganizationPreview {
        guard var plan = semanticOrganizationPlan, plan.id == planID,
              let original = plan.suggestions.first(where: { $0.id == suggestionID }),
              !folders.isEmpty, folders.count <= 6,
              folders.allSatisfy({ OrganizationContext.validatedFolderName($0) == $0 && !$0.hasPrefix(".") && !$0.contains("/") && !$0.contains(":") }) else { throw OpenFilesError.message("Enter up to six folder names, separated by /. Hidden, sensitive or invalid names are not allowed.") }
        let oldFolder = original.destination.deletingLastPathComponent()
        let replacement = folders.reduce(plan.destination) { $0.appendingPathComponent($1, isDirectory: true) }
        var reserved = Set(plan.suggestions.filter { $0.destination.deletingLastPathComponent() != oldFolder }.map { $0.destination.path.lowercased() })
        plan.suggestions = plan.suggestions.map { suggestion in
            guard suggestion.destination.deletingLastPathComponent() == oldFolder else { return suggestion }
            var target = replacement.appendingPathComponent(suggestion.source.lastPathComponent)
            var suffix = 2
            while FileManager.default.fileExists(atPath: target.path) || reserved.contains(target.path.lowercased()) {
                let ext = suggestion.source.pathExtension.isEmpty ? "" : "." + suggestion.source.pathExtension
                target = replacement.appendingPathComponent(suggestion.source.deletingPathExtension().lastPathComponent + " (\(suffix))" + ext); suffix += 1
            }
            reserved.insert(target.path.lowercased())
            return OrganizationSuggestion(id: suggestion.id, source: suggestion.source, destination: target, topic: folders.joined(separator: " / "), similarity: suggestion.similarity, margin: suggestion.margin, evidence: suggestion.evidence + "\nFolder path edited by you.", digest: suggestion.digest, stamp: suggestion.stamp)
        }
        plan.id = UUID(); semanticOrganizationPlan = plan
        return plan
    }

    /// Only selections from the exact displayed plan can be applied; discovery grants no move authority.
    public func applySemanticOrganization(planID: UUID, selected: Set<UUID>) async throws -> OrganizationReport {
        guard let plan = semanticOrganizationPlan, plan.id == planID,
              selected.isSubset(of: Set(plan.suggestions.map(\.id))) else { throw OpenFilesError.message("This preview has expired. Analyze your files again.") }
        semanticOrganizationPlan = nil
        var report = OrganizationReport()
        let fm = FileManager.default
        var changed: [URL] = []
        for suggestion in plan.suggestions where selected.contains(suggestion.id) {
            do {
                let source = suggestion.source
                var folderProtection: [String: Bool] = [:]
                guard SemanticOrganizer.exclusion(source, roots: MacScanScopes.reduce([plan.destination.deletingLastPathComponent()] + indexScopes()), output: plan.destination, appData: directory, excluded: state.indexSettings?.excludedFolders ?? [], folderProtection: &folderProtection) == nil else { throw OpenFilesError.message("Source is no longer eligible.") }
                guard try FileStamp.read(source) == suggestion.stamp, try FileIntegrity.digest(source) == suggestion.digest else { throw OpenFilesError.message("Changed since preview; skipped.") }
                try checkSnapshotEligibility(source)
                // Walk each destination component without following a substituted symbolic link.
                let anchor = plan.destination.deletingLastPathComponent()
                guard anchor.canonical == anchor else { throw OpenFilesError.message("Destination parent changed.") }
                let destinationFolder = suggestion.destination.deletingLastPathComponent().standardizedFileURL
                guard FileRules.contains(plan.destination, destinationFolder) else { throw OpenFilesError.message("Destination is outside the reviewed organization folder.") }
                let relative = Array(destinationFolder.pathComponents.dropFirst(plan.destination.standardizedFileURL.pathComponents.count))
                guard !relative.isEmpty, relative.count <= 6,
                      relative.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else { throw OpenFilesError.message("Invalid destination folders.") }
                var parent = anchor
                for component in [plan.destination.lastPathComponent] + relative {
                    parent.appendPathComponent(component, isDirectory: true)
                    if fm.fileExists(atPath: parent.path) {
                        let v = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        guard v.isDirectory == true, v.isSymbolicLink != true, parent.canonical == parent else { throw OpenFilesError.message("Destination contains a link or non-folder.") }
                    } else { try fm.createDirectory(at: parent, withIntermediateDirectories: false) }
                }
                try fm.copyItem(at: source, to: suggestion.destination)
                guard try FileStamp.read(source) == suggestion.stamp,
                      try FileIntegrity.digest(source) == suggestion.digest,
                      try FileIntegrity.digest(suggestion.destination) == suggestion.digest else { throw OpenFilesError.message("Changed during move; original retained.") }
                try fm.removeItem(at: source)
                changed += [source, suggestion.destination]; report.moved += 1
            } catch { report.errors.append("\(suggestion.source.path): \(error.localizedDescription)") }
        }
        if !changed.isEmpty {
            do { _ = try await synchronizeChanges(changed) }
            catch { report.errors.append("Files were moved, but the index needs a refresh: \(error.localizedDescription)") }
        }
        return report
    }
}
