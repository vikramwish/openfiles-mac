import Foundation
import OpenFilesCore

struct CloudPlacementChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Cloud recommendations rank large and older files and deduplicate paths", ranking),
        ("Cloud recommendations exclude sensitive files, projects, and provider folders", exclusions)
    ]
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func file(_ path: String, megabytes: Int64 = 30, days: Double = 0, sensitive: Bool = false, project: Bool = false) -> FileRecord {
        FileRecord(id: UUID(), url: URL(fileURLWithPath: path), root: URL(fileURLWithPath: "/tmp/fixture"),
                   size: megabytes * 1_024 * 1_024, modified: now.addingTimeInterval(-days * 86_400),
                   isProject: project, sensitive: sensitive, vector: nil)
    }
    static func ranking() async throws {
        let large = file("/tmp/fixture/movie.mp4", megabytes: 50)
        let older = file("/tmp/fixture/report.pdf", megabytes: 2, days: 100)
        let recent = file("/tmp/fixture/recent.pdf", megabytes: 2)
        let tiny = file("/tmp/fixture/empty.txt", megabytes: 0, days: 200)
        let results = CloudPlacementSuggestions.suggest([older, recent, large, large, tiny], now: now)
        checkEqual(results.map(\.source), [large.url, older.url])
        checkTrue(results[0].reason.contains("Large"))
        checkTrue(results[1].reason.contains("90 days"))
        checkEqual(CloudPlacementSuggestions.suggest([older, large], now: now, limit: 1).map(\.source), [large.url])
        checkTrue(CloudPlacementSuggestions.suggest([large], now: now, limit: -1).isEmpty)
    }
    static func exclusions() async throws {
        let eligible = file("/tmp/fixture/Library/CloudStorage-not-a-provider/notes.pdf")
        let results = CloudPlacementSuggestions.suggest([
            file("/tmp/fixture/secret.txt"),
            file("/tmp/fixture/notes.txt", sensitive: true),
            file("/tmp/fixture/project", project: true),
            file("/tmp/fixture/Library/CloudStorage/OneDrive/docs.pdf"),
            file("/tmp/fixture/Library/Mobile Documents/com~apple~CloudDocs/docs.pdf"),
            eligible
        ], now: now)
        checkEqual(results.map(\.source), [eligible.url])
    }
}
