import Foundation

/// Folder names come from this corpus, never from a fixed topical taxonomy.
public struct OrganizationContext: Sendable {
    public let topic: String
    public let folders: [String]
    public let reasons: [String]
    private static let containers: Set<String> = ["documents", "downloads", "desktop", "pictures", "images", "photos", "files", "misc", "other", "unsorted", "temp", "tmp", "new folder", "untitled folder", "organized"]
    private static let noise: Set<String> = ["a", "an", "the", "and", "or", "to", "of", "in", "on", "for", "from", "with", "by", "is", "are", "this", "that", "my", "your", "all", "file", "files", "document", "documents", "notes", "note", "copy", "final", "draft", "version", "pdf", "txt", "jpg", "jpeg", "png", "img", "dsc", "scan", "scanned", "untitled", "unknown"]
    private struct Evidence {
        let file: FileRecord
        let words: Set<String>
        let filename: [String]
        let existing: [String]
        let labels: [String]
        let place: String?
    }
    public static func suggest(for file: FileRecord, fallbackTopic: String? = nil) -> Self? {
        suggestions(for: [file], roots: [file.root])[file.id]
    }
    public static func suggestions(for files: [FileRecord], roots: [URL]) -> [UUID: Self] {
        func meaningful(_ word: String) -> Bool {
            word.count >= 3 && !noise.contains(word) && word.contains(where: \.isLetter) && !FileRules.sensitive(word)
        }
        let evidence: [Evidence] = files.filter { !$0.sensitive && !$0.isProject }.map { file in
            let filename = FileSearchQuery.words(file.url.deletingPathExtension().lastPathComponent).filter(meaningful)
            let root = roots.filter { FileRules.contains($0, file.url) }.max { $0.pathComponents.count < $1.pathComponents.count } ?? file.root
            let relative = file.url.deletingLastPathComponent().standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count)
            let existing = relative.filter { !containers.contains($0.lowercased()) }.compactMap(clean).suffix(4)
            let labels = (file.imageContent?.subjects ?? []).filter { $0.confidence >= 0.45 }.sorted { $0.confidence > $1.confidence }.compactMap { clean($0.name) }
            let place = file.imageContent?.location?.names.compactMap(clean).first
                ?? file.imageContent?.location?.searchKeys.sorted().first.flatMap { clean($0.capitalized) }
            let words = Set(filename).union((file.searchTerms ?? []).filter(meaningful).prefix(96))
                .union(labels.flatMap(FileSearchQuery.words).filter(meaningful))
                .union(existing.flatMap(FileSearchQuery.words).filter(meaningful))
            return Evidence(file: file, words: words, filename: filename, existing: Array(existing), labels: labels, place: place)
        }.sorted { $0.file.url.path < $1.file.url.path }
        var postings: [String: Set<Int>] = [:]
        for (index, item) in evidence.enumerated() {
            for word in item.words { postings[word, default: []].insert(index) }
        }
        // Existing user-created folder names form anchors for files scattered elsewhere.
        var anchors: [String: (folders: [String], words: Set<String>)] = [:]
        for item in evidence where !item.existing.isEmpty {
            let key = item.existing.joined(separator: "/")
            let words = anchors[key]?.words ?? []
            anchors[key] = (item.existing, words.union(item.words))
        }
        var anchorPostings: [String: Set<String>] = [:]
        for (key, anchor) in anchors { for word in anchor.words { anchorPostings[word, default: []].insert(key) } }
        var results: [UUID: Self] = [:]
        for (index, item) in evidence.enumerated() {
            var folders = item.existing
            var reasons: [String] = []
            if !folders.isEmpty { reasons.append("Preserves your existing folder names: " + folders.joined(separator: "/") + ".") }
            else {
                var votes: [String: Int] = [:]
                for word in item.words { for key in anchorPostings[word] ?? [] { votes[key, default: 0] += 1 } }
                let candidates = votes.filter { $0.value >= 2 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(48).compactMap { anchors[$0.key] }
                let ranked = candidates.compactMap { anchor -> (folders: [String], hits: [String], score: Double)? in
                    let hits = item.words.intersection(anchor.words).sorted()
                    guard hits.count >= 2 else { return nil }
                    let score = hits.reduce(0.0) { $0 + log(1 + Double(evidence.count) / Double(postings[$1]?.count ?? 1)) }
                    return (anchor.folders, hits, score)
                }.sorted { $0.score == $1.score ? $0.folders.joined() < $1.folders.joined() : $0.score > $1.score }
                if let first = ranked.first, ranked.count == 1 || first.score > ranked[1].score * 1.25 {
                    folders = first.folders
                    reasons.append("Uses an existing folder name, supported by shared indexed terms: " + first.hits.prefix(5).joined(separator: ", ") + ".")
                }
            }
            if folders.isEmpty, let place = item.place {
                folders = [place]
                if let label = item.labels.first, label.localizedCaseInsensitiveCompare(place) != .orderedSame { folders.append(label.capitalized) }
                reasons.append("Name comes from embedded photo location and on-device subject labels.")
            }
            if folders.isEmpty {
                // Prefer a shared phrase in filename order; no invented project or client names.
                let shared = item.filename.filter { (postings[$0]?.count ?? 0) >= 2 }
                if !shared.isEmpty {
                    let peers = shared.reduce(into: Set<Int>()) { $0.formUnion(postings[$1] ?? []) }.subtracting([index])
                    let name = shared.prefix(3).joined(separator: " ").capitalized
                    if let name = clean(name) { folders = [name]; reasons.append("Folder name uses shared filename terms across \(peers.count + 1) files: \(shared.prefix(3).joined(separator: ", ")).") }
                } else if let label = item.labels.first {
                    folders = [label.capitalized]
                    reasons.append("Folder name uses the image classifier's actual subject label: \(label).")
                } else if item.filename.count >= 2 {
                    folders = [item.filename.prefix(3).joined(separator: " ").capitalized]
                    reasons.append("Folder name uses specific words from the filename; review or rename it.")
                } else {
                    let sharedContent = item.words.filter { (postings[$0]?.count ?? 0) >= 2 }.sorted {
                        let a = postings[$0]?.count ?? 0, b = postings[$1]?.count ?? 0
                        return a == b ? $0 < $1 : a > b
                    }.prefix(3)
                    if sharedContent.count >= 2 {
                        folders = [sharedContent.joined(separator: " ").capitalized]
                        reasons.append("Folder name uses recurring indexed content terms: " + sharedContent.joined(separator: ", ") + ".")
                    }
                }
            }
            folders = folders.compactMap(clean)
            guard !folders.isEmpty else { continue }
            results[item.file.id] = Self(topic: folders.joined(separator: " / "), folders: folders, reasons: reasons)
        }
        return results
    }
    /// Untrusted file metadata produces names, never paths or commands.
    public static func clean(_ input: String) -> String? {
        let text = input.components(separatedBy: .controlCharacters).joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard !text.isEmpty, !FileRules.sensitive(text) else { return nil }
        return String(text.prefix(64))
    }
}
