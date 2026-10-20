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
    public let id: UUID
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
        guard let root = roots.filter({ FileRules.contains($0, source) }).min(by: { $0.path.count < $1.path.count }) else { return "Outside personal file scope" }
        if FileRules.contains(output, source) { return "Already organized" }
        if FileRules.contains(appData, source) || excluded.contains(where: { FileRules.contains($0, source) }) { return "Excluded location" }
        guard source.standardizedFileURL.path == source.canonical.path else { return "Symbolic link" }
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
        let roots = [home] + state.roots.map(\.canonical)
        let snapshot = state.files
        var result = OrganizationPreview(id: UUID(), created: Date(), destination: output, indexedFiles: snapshot.count)
        var prototypes: [String: [Double]] = [:]
        for topic in OrganizationTopic.defaults {
            try Task.checkCancellation()
            if let vector = await queryBackend.vector(for: topic.description) { prototypes[topic.id] = vector }
        }
        try Task.checkCancellation()
        guard semanticOrganizationGeneration == generation else { throw CancellationError() }
        result.modelAvailable = prototypes.count == OrganizationTopic.defaults.count
        guard result.modelAvailable else { semanticOrganizationPlan = result; return result }
        var reserved = Set<String>()
        var folderProtection: [String: Bool] = [:]
        for file in snapshot.sorted(by: { $0.url.path < $1.url.path }) {
            try Task.checkCancellation()
            let source = file.url
            func skip(_ reason: String) { result.skipped[reason, default: 0] += 1 }
            if file.sensitive || FileRules.sensitive(file.name) { skip("Potentially sensitive"); continue }
            if file.isProject { skip("App, system or project files"); continue }
            guard let meta = file.indexMetadata, meta.engine == queryBackend.identifier,
                  !meta.detail.hasPrefix("Filename only:"), let vector = file.vector else { skip("Content embedding not available"); continue }
            if let reason = SemanticOrganizer.exclusion(source, roots: roots, output: output, appData: directory, excluded: state.indexSettings?.excludedFolders ?? [], folderProtection: &folderProtection) { skip(reason); continue }
            guard let match = SemanticOrganizer.classify(vector, topics: prototypes) else { skip("Uncertain topic match"); continue }
            if result.suggestions.count >= max(1, limit) { result.deferred += 1; continue }
            do {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { skip("Not a regular file"); continue }
                let stamp = try FileStamp.read(source)
                guard stamp == meta.stamp, Date().timeIntervalSince(stamp.modified) > 10 else { skip("Changed or recently edited; reindex needed"); continue }
                try checkSnapshotEligibility(source)
                let digest = try FileIntegrity.digest(source)
                guard try FileStamp.read(source) == stamp else { skip("Changed during analysis"); continue }
                let folder = output.appendingPathComponent(match.topic, isDirectory: true)
                var target = folder.appendingPathComponent(file.name)
                var suffix = 2
                while FileManager.default.fileExists(atPath: target.path) || reserved.contains(target.path.lowercased()) {
                    let ext = source.pathExtension.isEmpty ? "" : "." + source.pathExtension
                    target = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + " (\(suffix))" + ext); suffix += 1
                }
                reserved.insert(target.path.lowercased())
                result.suggestions.append(.init(id: file.id, source: source, destination: target, topic: match.topic, similarity: match.similarity, margin: match.margin, evidence: meta.detail, digest: digest, stamp: stamp))
            } catch { skip("Unreadable or sensitive content") }
        }
        semanticOrganizationPlan = result
        return result
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
                guard SemanticOrganizer.exclusion(source, roots: [plan.destination.deletingLastPathComponent()] + state.roots.map(\.canonical), output: plan.destination, appData: directory, excluded: state.indexSettings?.excludedFolders ?? [], folderProtection: &folderProtection) == nil else { throw OpenFilesError.message("Source is no longer eligible.") }
                guard try FileStamp.read(source) == suggestion.stamp, try FileIntegrity.digest(source) == suggestion.digest else { throw OpenFilesError.message("Changed since preview; skipped.") }
                try checkSnapshotEligibility(source)
                // Walk each destination component without following a substituted symbolic link.
                let anchor = plan.destination.deletingLastPathComponent()
                guard anchor.canonical == anchor else { throw OpenFilesError.message("Destination parent changed.") }
                var parent = anchor
                for component in [plan.destination.lastPathComponent, suggestion.topic] {
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
