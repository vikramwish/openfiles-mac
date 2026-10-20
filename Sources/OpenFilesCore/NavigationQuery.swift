import Foundation

public enum FileGrouping: String, CaseIterable, Codable, Sendable {
    case folder = "Folder", kind = "Kind", month = "Month"
}

public struct SmartCollection: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var query: String
    public var created = Date()
    public init(query: String) { self.query = query }
}

/// A deterministic query plan, evaluated against cached metadata and postings, never by an LLM.
public struct NavigationQuery: Sendable {
    public let topic: FileSearchQuery
    public var extensions: Set<String> = []
    public var after: Date?
    public var before: Date?
    public var location: String?
    public var photoLocation: String?
    public var grouping: FileGrouping?
    public var newestFirst = false
    public var browseAll = false
    public var hasFilters: Bool { !extensions.isEmpty || after != nil || before != nil || location != nil || photoLocation != nil || newestFirst }
    public var isEmpty: Bool { topic.terms.isEmpty && !hasFilters && !browseAll }
    public init(_ input: String, now: Date = Date(), calendar: Calendar = .current) {
        var text = input.lowercased()
        for (phrase, mode) in [("grouped by project", FileGrouping.folder), ("group by project", .folder), ("grouped by folder", .folder), ("group by folder", .folder), ("grouped by kind", .kind), ("group by kind", .kind), ("grouped by type", .kind), ("group by type", .kind), ("grouped by month", .month), ("group by month", .month)] {
            if text.contains(phrase) { grouping = mode; text = text.replacingOccurrences(of: phrase, with: " ") }
        }
        for word in ["recent", "latest", "newest"] where FileSearchQuery.words(text).contains(word) {
            newestFirst = true; text = text.replacingOccurrences(of: "\\b\(word)\\b", with: " ", options: .regularExpression)
        }
        let day = calendar.startOfDay(for: now)
        let dates: [(String, Date?, Date?)] = [
            ("today", day, nil),
            ("yesterday", calendar.date(byAdding: .day, value: -1, to: day), day),
            ("this week", calendar.dateInterval(of: .weekOfYear, for: now)?.start, nil),
            ("last week", calendar.date(byAdding: .weekOfYear, value: -1, to: now).flatMap { calendar.dateInterval(of: .weekOfYear, for: $0)?.start }, calendar.dateInterval(of: .weekOfYear, for: now)?.start),
            ("this month", calendar.dateInterval(of: .month, for: now)?.start, nil),
            ("last month", calendar.date(byAdding: .month, value: -1, to: now).flatMap { calendar.dateInterval(of: .month, for: $0)?.start }, calendar.dateInterval(of: .month, for: now)?.start),
            ("this year", calendar.dateInterval(of: .year, for: now)?.start, nil)
        ]
        for (phrase, start, end) in dates where text.contains(phrase) {
            after = start; before = end; text = text.replacingOccurrences(of: phrase, with: " "); break
        }
        for folder in ["downloads", "documents", "desktop", "pictures", "music", "movies"] {
            for prefix in ["in ", "from ", "under "] where text.contains(prefix + folder) {
                location = folder; text = text.replacingOccurrences(of: prefix + folder, with: " ")
            }
        }
        if let range = text.range(of: #"\bin\s+"[^"]+""#, options: .regularExpression) {
            let value = String(text[range]); location = value.components(separatedBy: "\"").dropFirst().first
            text.removeSubrange(range)
        }
        // Explicit capture wording works for any file query; image queries also accept “in Sydney”.
        let photoQuery = FileSearchQuery.words(text).contains { ["photos", "pictures", "images"].contains($0) }
        let placePattern = photoQuery ? #"\b(?:(?:taken|captured|shot)\s+)?(?:in|near|around|at)\s+([\p{L}][\p{L} .'-]*)$"# : #"\b(?:taken|captured|shot)\s+(?:in|near|around|at)\s+([\p{L}][\p{L} .'-]*)$"#
        if let expression = try? NSRegularExpression(pattern: placePattern),
           let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text), let whole = Range(match.range, in: text) {
            photoLocation = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            text.removeSubrange(whole)
        }
        let kinds: [(String, Set<String>)] = [
            ("pdfs", ["pdf"]), ("pdf", ["pdf"]),
            ("images", ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "svg", "webp"]), ("pictures", ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]), ("photos", ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]),
            ("spreadsheets", ["xlsx", "xls", "csv", "numbers"]), ("presentations", ["ppt", "pptx", "key"]),
            ("videos", ["mov", "mp4", "m4v", "avi"]), ("audio", ["mp3", "wav", "m4a", "aiff", "flac"]),
            ("archives", ["zip", "gz", "tar", "dmg"])
        ]
        for (word, values) in kinds {
            let pattern = "(?<![\\w.])\(word)(?![\\w.])"
            if text.range(of: pattern, options: .regularExpression) != nil { extensions.formUnion(values); text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression) }
        }
        for filler in ["modified", "updated", "changed", "from", "in"] {
            text = text.replacingOccurrences(of: "\\b\(filler)\\b", with: " ", options: .regularExpression)
        }
        topic = FileSearchQuery(text)
        browseAll = topic.terms.isEmpty && ["files", "documents"].contains(where: { FileSearchQuery.words(input).contains($0) })
    }
    public func accepts(_ file: FileRecord) -> Bool {
        if !extensions.isEmpty && !extensions.contains(file.url.pathExtension.lowercased()) { return false }
        if let photoLocation, file.sensitive || file.imageContent?.location?.matches(photoLocation) != true { return false }
        if let after, file.modified < after { return false }
        if let before, file.modified >= before { return false }
        if let location, !file.url.deletingLastPathComponent().pathComponents.contains(where: { $0.localizedCaseInsensitiveCompare(location) == .orderedSame }) { return false }
        return true
    }
}

/// The searchable index is rebuilt from persisted records on launch, then updated per checkpoint.
/// Readers copy a COW snapshot under a lock; matching never touches disk or waits for inference.
public final class SearchCatalog: @unchecked Sendable {
    private struct Snapshot {
        var files: [String: FileRecord] = [:]
        var postings: [String: Set<String>] = [:]
        var vocabulary: [String] = []
        var recentPaths: [String] = []
        var names: [String: String] = [:]
        var nameWords: [String: Set<String>] = [:]
        var documentWords: [String: Set<String>] = [:]
        var visualWords: [String: Set<String>] = [:]
        var metadataWords: [String: Set<String>] = [:]
        var vectorNorms: [String: Double] = [:]
        var vocabularyDirty = false
        var revision: UInt64 = 0
    }
    private let lock = NSLock()
    private let writer = NSLock()
    private var state = Snapshot()
    public init() {}
    public var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return state.revision }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return state.files.count }
    public func replace(_ files: [FileRecord]) {
        writer.lock(); defer { writer.unlock() }
        lock.lock(); let previous = state; lock.unlock()
        let allowed = files.filter { FileSearchQuery.allows($0.url) }
        if previous.files.count == allowed.count && allowed.allSatisfy({ previous.files[$0.url.path] == $0 }) { return }
        var next = Snapshot()
        for file in allowed { Self.insert(file, into: &next) }
        next.vocabulary = next.postings.keys.sorted(); next.vocabularyDirty = false
        next.recentPaths = next.files.keys.sorted { Self.newer($0, than: $1, files: next.files) }
        next.revision = previous.revision + 1
        lock.lock(); state = next; lock.unlock()
    }
    public func upsert(_ files: [FileRecord], removing paths: Set<String> = []) {
        writer.lock(); defer { writer.unlock() }
        lock.lock(); var next = state; lock.unlock()
        var changed = false
        var affected = paths
        for path in paths where next.files[path] != nil { Self.remove(path, from: &next); changed = true }
        for file in files {
            guard next.files[file.url.path] != file else { continue }
            Self.remove(file.url.path, from: &next); Self.insert(file, into: &next); changed = true
            affected.insert(file.url.path)
        }
        guard changed else { return }
        if next.vocabularyDirty { next.vocabulary = next.postings.keys.sorted(); next.vocabularyDirty = false }
        let kept = next.recentPaths.filter { !affected.contains($0) }
        let updates = affected.filter { next.files[$0] != nil }.sorted { Self.newer($0, than: $1, files: next.files) }
        var merged: [String] = []; merged.reserveCapacity(kept.count + updates.count)
        var i = 0, j = 0
        while i < kept.count && j < updates.count {
            if Self.newer(kept[i], than: updates[j], files: next.files) { merged.append(kept[i]); i += 1 }
            else { merged.append(updates[j]); j += 1 }
        }
        merged.append(contentsOf: kept.dropFirst(i)); merged.append(contentsOf: updates.dropFirst(j))
        next.recentPaths = merged
        next.revision += 1
        // Readers take a shallow immutable snapshot. Expensive posting updates happen
        // outside the reader lock, so background indexing cannot block a keypress.
        lock.lock(); state = next; lock.unlock()
    }
    private static func newer(_ a: String, than b: String, files: [String: FileRecord]) -> Bool {
        guard let first = files[a], let second = files[b] else { return a < b }
        return first.modified == second.modified ? a < b : first.modified > second.modified
    }
    private static func insert(_ file: FileRecord, into state: inout Snapshot) {
        guard FileSearchQuery.allows(file.url) else { return }
        let path = file.url.path; state.files[path] = file
        let names = Set(FileSearchQuery.words(file.name)), words = names.union(file.sensitive ? [] : file.searchTerms ?? [])
        if !file.sensitive, let visual = file.imageContent { state.visualWords[path] = visual.subjectTerms }
        state.names[path] = file.name.lowercased()
        state.nameWords[path] = names; state.documentWords[path] = words
        let metadata = Self.metadataTerms(file)
        state.metadataWords[path] = metadata
        if let vector = file.vector {
            let norm = sqrt(VectorMath.dot(vector, vector))
            if norm.isFinite && norm > 0 { state.vectorNorms[path] = norm }
        }
        for term in words.union(metadata) {
            if state.postings[term] == nil { state.vocabularyDirty = true }
            state.postings[term, default: []].insert(path)
        }
    }
    private static func metadataTerms(_ file: FileRecord) -> Set<String> {
        var terms = Set(["#ext:" + file.url.pathExtension.lowercased()] + file.url.deletingLastPathComponent().pathComponents.map { "#folder:" + $0.lowercased() })
        if !file.sensitive, let place = file.imageContent?.location {
            terms.formUnion(place.searchKeys.map { "#place:" + $0 })
        }
        return terms
    }
    private static func remove(_ path: String, from state: inout Snapshot) {
        guard state.files.removeValue(forKey: path) != nil else { return }
        let metadata = state.metadataWords.removeValue(forKey: path) ?? []
        let words = state.documentWords.removeValue(forKey: path) ?? []
        state.visualWords.removeValue(forKey: path); state.vectorNorms.removeValue(forKey: path)
        state.names.removeValue(forKey: path); state.nameWords.removeValue(forKey: path)
        for term in words.union(metadata) {
            state.postings[term]?.remove(path)
            if state.postings[term]?.isEmpty == true { state.postings.removeValue(forKey: term); state.vocabularyDirty = true }
        }
    }
    public func matches(_ input: String, now: Date = Date(), vector: [Double]? = nil, engine: String? = nil, acceptsLegacyVectors: Bool = false, limit: Int = 100) -> [FileSearchMatch] {
        let plan = NavigationQuery(input, now: now)
        guard !plan.isEmpty, limit > 0 else { return [] }
        let phrase = plan.topic.text
        lock.lock(); let snapshot = state; lock.unlock()
        func matching(_ term: String, prefix: Bool) -> Set<String> {
            let tokens = FileSearchQuery.words(term)
            if tokens.count > 1 { return tokens.reduce(nil as Set<String>?) { result, word in result.map { $0.intersection(snapshot.postings[word] ?? []) } ?? snapshot.postings[word] ?? [] } ?? [] }
            var paths = snapshot.postings[term] ?? []
            if prefix && term.count >= 2 {
                var low = 0, high = snapshot.vocabulary.count
                while low < high { let middle = (low + high) / 2; if snapshot.vocabulary[middle] < term { low = middle + 1 } else { high = middle } }
                for word in snapshot.vocabulary.dropFirst(low).prefix(64) {
                    guard word.hasPrefix(term) else { break }; paths.formUnion(snapshot.postings[word] ?? [])
                }
            }
            return paths
        }
        var candidates: Set<String>?
        var union = Set<String>()
        for (index, group) in plan.topic.groups.enumerated() {
            let paths = group.reduce(into: Set<String>()) { $0.formUnion(matching($1, prefix: vector == nil && index == plan.topic.groups.count - 1)) }
            union.formUnion(paths); candidates = candidates.map { $0.intersection(paths) } ?? paths
        }
        // Optional embedding refinement considers only documents with matching lexical evidence.
        if vector != nil && plan.topic.groups.count > 2 { candidates = union }
        if !plan.extensions.isEmpty {
            let paths = plan.extensions.reduce(into: Set<String>()) { $0.formUnion(snapshot.postings["#ext:" + $1] ?? []) }
            candidates = candidates.map { $0.intersection(paths) } ?? paths
        }
        if let location = plan.location {
            let paths = snapshot.postings["#folder:" + location] ?? []
            candidates = candidates.map { $0.intersection(paths) } ?? paths
        }
        if let place = plan.photoLocation {
            let paths = snapshot.postings["#place:" + PhotoLocation.normalized(place)] ?? []
            candidates = candidates.map { $0.intersection(paths) } ?? paths
        }
        if plan.topic.terms.isEmpty {
            let ordered: [String]
            if let candidates, candidates.count < max(1, snapshot.recentPaths.count / 8) {
                ordered = candidates.sorted { Self.newer($0, than: $1, files: snapshot.files) }
            } else { ordered = snapshot.recentPaths }
            var results: [FileSearchMatch] = []; results.reserveCapacity(min(limit, ordered.count))
            var start = 0
            if let before = plan.before {
                var end = ordered.count
                while start < end {
                    let middle = (start + end) / 2
                    if let file = snapshot.files[ordered[middle]], file.modified >= before { start = middle + 1 }
                    else { end = middle }
                }
            }
            for path in ordered.dropFirst(start) {
                guard let file = snapshot.files[path] else { continue }
                if let after = plan.after, file.modified < after { break }
                if let candidates, !candidates.contains(path) { continue }
                if let place = plan.photoLocation, file.sensitive || file.imageContent?.location?.matches(place) != true { continue }
                results.append(FileSearchMatch(file: file, score: 1, reason: plan.photoLocation != nil ? "Photo location metadata" : "Metadata filter"))
                if results.count == limit { break }
            }
            return results
        }
        let paths = candidates ?? Set(snapshot.files.keys)
        let queryNorm = vector.map { sqrt(VectorMath.dot($0, $0)) } ?? 0
        func evaluate(_ path: String) -> (path: String, match: FileSearchMatch)? {
            guard let file = snapshot.files[path] else { return nil }
            if let place = plan.photoLocation, file.sensitive || file.imageContent?.location?.matches(place) != true { return nil }
            if let after = plan.after, file.modified < after { return nil }
            if let before = plan.before, file.modified >= before { return nil }
            if plan.topic.terms.isEmpty { return (path, FileSearchMatch(file: file, score: 1, reason: plan.photoLocation != nil ? "Photo location metadata" : "Metadata filter")) }
            let nameScore = plan.topic.coverage(words: snapshot.nameWords[path] ?? [])
            let similarity: Double
            if let query = vector, let document = file.vector, !file.sensitive,
               file.indexMetadata.map({ $0.engine == engine }) ?? acceptsLegacyVectors,
               let norm = snapshot.vectorNorms[path], queryNorm.isFinite, queryNorm > 0 {
                similarity = VectorMath.dot(query, document) / (queryNorm * norm)
            } else { similarity = 0 }
            let coverage = plan.topic.coverage(words: snapshot.documentWords[path] ?? [])
            let score: Double
            if plan.topic.terms.isEmpty { score = 1 }
            else if coverage == 1 || (plan.topic.groups.count > 2 && coverage >= 0.5 && similarity >= 0.2) {
                score = ((snapshot.names[path]?.contains(phrase) ?? false) ? 3 : 0) + nameScore * 5 + coverage * 2 + max(0, min(1, similarity)) * 0.4
            }
            else if vector == nil { score = nameScore * 5 + 1 } // prefix match already grounded by postings
            else { return nil }
            let visualCoverage = plan.topic.coverage(words: snapshot.visualWords[path] ?? [])
            let reason = plan.topic.terms.isEmpty ? "Metadata filter" : nameScore == 1 ? "Filename matches" : visualCoverage == 1 ? "Image subject match" : file.imageContent != nil ? "Image text / subject match" : "Indexed text matches"
            return (path, FileSearchMatch(file: file, score: score, reason: reason))
        }
        func better(_ a: (path: String, match: FileSearchMatch), _ b: (path: String, match: FileSearchMatch)) -> Bool {
            if plan.newestFirst || plan.topic.terms.isEmpty {
                return a.match.file.modified == b.match.file.modified ? a.path < b.path : a.match.file.modified > b.match.file.modified
            }
            return a.match.score == b.match.score ? a.path < b.path : a.match.score > b.match.score
        }
        // Keep only the best K, rather than sorting every matching document on every keypress.
        var best: [(path: String, match: FileSearchMatch)] = []
        best.reserveCapacity(limit + 1)
        for path in paths {
            guard let value = evaluate(path) else { continue }
            if best.count == limit, let last = best.last, !better(value, last) { continue }
            var low = 0, high = best.count
            while low < high { let middle = (low + high) / 2; if better(value, best[middle]) { high = middle } else { low = middle + 1 } }
            best.insert(value, at: low)
            if best.count > limit { best.removeLast() }
        }
        return best.map(\.match)
    }
    /// Sparse file→term→file traversal; never materializes an all-pairs similarity graph.
    public func relatedFiles(to source: URL, limit: Int = 8) -> [FileRelationship] {
        guard limit > 0 else { return [] }
        lock.lock(); let snapshot = state; lock.unlock()
        let path = source.path
        guard let origin = snapshot.files[path], !origin.sensitive else { return [] }
        let stop: Set<String> = ["the", "and", "of", "to", "a", "in", "is", "for", "on", "with", "this", "that", "from", "are", "be", "as", "by", "or", "it", origin.url.pathExtension.lowercased()]
        let features = (snapshot.documentWords[path] ?? []).compactMap { term -> (String, Double)? in
            guard term.count > 2, !stop.contains(term), let postings = snapshot.postings[term],
                  postings.count > 1, postings.count <= max(32, snapshot.files.count / 2) else { return nil }
            return (term, log(1 + Double(snapshot.files.count) / Double(postings.count)))
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(24)
        var votes: [String: Double] = [:]
        for (term, weight) in features {
            for candidate in (snapshot.postings[term] ?? []).prefix(128) where candidate != path {
                if votes.count < 1024 || votes[candidate] != nil { votes[candidate, default: 0] += weight }
            }
        }
        // When lexical overlap is sparse, inspect a bounded local neighborhood of the
        // same format; the content vector still has to substantiate a relationship.
        if votes.count < min(limit, 32) {
            let peers = snapshot.postings["#ext:" + origin.url.pathExtension.lowercased()] ?? []
            for candidate in peers.prefix(256) where candidate != path && votes[candidate] == nil { votes[candidate] = 0 }
        }
        var relationships: [FileRelationship] = []
        for (candidate, weight) in votes {
            guard let file = snapshot.files[candidate], !file.sensitive else { continue }
            var similarity: Double? = nil
            if let a = origin.vector, let b = file.vector, a.count == b.count,
               origin.indexMetadata?.engine == file.indexMetadata?.engine,
               let na = snapshot.vectorNorms[path], let nb = snapshot.vectorNorms[candidate] {
                similarity = VectorMath.dot(a, b) / (na * nb)
            }
            guard weight > 0 || (similarity ?? 0) >= 0.65 else { continue }
            let shared = features.filter { snapshot.documentWords[candidate]?.contains($0.0) == true }.map(\.0)
            relationships.append(FileRelationship(file: file, score: weight + max(0, similarity ?? 0) * 2,
                similarity: similarity, sharedTerms: Array(shared.prefix(4))))
        }
        return Array(relationships.sorted { $0.score == $1.score ? $0.file.url.path < $1.file.url.path : $0.score > $1.score }.prefix(min(limit, 32)))
    }

}


public struct FileRelationship: Identifiable, Sendable {
    public var id: UUID { file.id }
    public let file: FileRecord
    public let score: Double
    public let similarity: Double?
    public let sharedTerms: [String]
}
