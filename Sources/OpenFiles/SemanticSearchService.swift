import Foundation
import AppKit

/// Client and lifecycle manager for the local Python semantic-search service
/// (finder_search): documents via BGE-small, photos and videos via SigLIP2 —
/// all on-device, no cloud. The service exposes a small JSON API on localhost:
///
///   GET  /health            liveness + index statistics (no model loading)
///   GET  /api/search?q=...  {documents: [...], media: [...]}
///
/// If the service is not running, we launch it from the repository copy of
/// the engine (`.venv/bin/python -m finder_search.cli serve`). The repository
/// location defaults to ~/Desktop/OpenFiles and can be overridden with the
/// `semanticSearchRoot` user default. When the engine is unavailable the app
/// silently falls back to its built-in NLEmbedding search and Spotlight.
@MainActor
final class SemanticSearchService {
    static let shared = SemanticSearchService()

    private let port = 7862
    private var process: Process?
    private var launchFailedAt: Date?
    private let retryInterval: TimeInterval = 60

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Where the Python engine lives (repo root with finder_search/ and .venv/).
    var engineRoot: URL {
        if let custom = UserDefaults.standard.string(forKey: "semanticSearchRoot") {
            let url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
            if hasEngine(at: url) { return url }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent("Desktop/OpenFiles", isDirectory: true)]
        return candidates.first { hasEngine(at: $0) } ?? candidates[0]
    }

    private func hasEngine(at url: URL) -> Bool {
        let python = url.appendingPathComponent(".venv/bin/python")
        let pkg = url.appendingPathComponent("finder_search/cli.py")
        return FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: pkg.path)
    }

    // MARK: lifecycle

    /// Returns true when the service answers /health. Launches it if needed.
    func ensureRunning() async -> Bool {
        if await isHealthy() { return true }
        if let failed = launchFailedAt, Date().timeIntervalSince(failed) < retryInterval { return false }
        guard launch() else { launchFailedAt = Date(); return false }
        // The server binds within a second; model loading is lazy and happens
        // on the first search, so a short poll is enough.
        for _ in 0..<40 where !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            if await isHealthy() { return true }
        }
        launchFailedAt = Date()
        return false
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        return true
    }

    @discardableResult
    private func launch() -> Bool {
        let root = engineRoot
        let python = root.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        let process = Process()
        process.executableURL = python
        process.currentDirectoryURL = root
        process.arguments = ["-m", "finder_search.cli", "serve", "--no-browser", "--port", String(port)]
        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + existing
        process.environment = environment
        // Keep the daemon quiet; logs go to Application Support.
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = support.appendingPathComponent("OpenFiles", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let log = dir.appendingPathComponent("semantic-search.log")
            if let handle = try? FileHandle(forWritingTo: log) {
                _ = try? handle.seekToEnd()
                process.standardOutput = handle
                process.standardError = handle
            }
        }
        do {
            try process.run()
            self.process = process
            return true
        } catch { return false }
    }

    // MARK: search

    private struct SearchResult: Codable {
        struct Hit: Codable {
            let path: String
            let score: Double
            let kind: String
        }
        let documents: [Hit]
        let media: [Hit]
    }

    /// Semantic search over documents, photos and videos. Returns file URLs,
    /// best first (documents then media). Empty when the service is down.
    func search(_ text: String) async -> [URL] {
        guard await ensureRunning(), !text.isEmpty else { return [] }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15   // first query may lazily load the models
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let result = try? JSONDecoder().decode(SearchResult.self, from: data) else { return [] }
        let hits = result.documents + result.media
        return hits.prefix(100).map { URL(fileURLWithPath: $0.path) }
    }

    /// Terminate the daemon (called when the app quits).
    func stop() {
        process?.terminate()
        process = nil
    }
}
