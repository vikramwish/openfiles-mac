import Foundation
import OpenFilesCore

struct AutomaticHistoryChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Automatic history is opt-in and skips unchanged saved contents", changes),
        ("Automatic history persists selections and respects pause and removal", persistence),
        ("Automatic history rejects sensitive contents, links, and excluded folders", exclusions),
        ("Automatic history preserves manual versions while rotating automatic versions", retention),
        ("Automatic history refuses a full budget without losing existing versions", budget),
        ("Automatic history failed snapshot preserves source and prior snapshot", failure),
        ("Automatic folder history captures whole projects and rejects incomplete snapshots", project)
    ]
    private static func fixture(limits: AutomaticHistoryLimits = .init(quietSeconds: 0), _ body: (FileLibrary, AutomaticHistory, URL, URL) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesAutomatic-\(UUID())").resolvingSymlinksInPath()
        let files = base.appendingPathComponent("Files"), data = base.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = FileLibrary(directory: data)
        _ = try await library.load()
        let history = AutomaticHistory(library: library, directory: data, limits: limits)
        try await body(library, history, files, data)
    }
    private static func write(_ url: URL, _ value: String) throws { try Data(value.utf8).write(to: url, options: .atomic) }
    private static func changes() async throws {
        try await fixture { library, history, files, _ in
            let file = files.appendingPathComponent("Draft.txt")
            try write(file, "first saved draft")
            _ = try await history.checkNow()
            let before = await library.current()
            checkTrue(before.versions.isEmpty)
            _ = try await history.add([file])
            let first = try await history.checkNow()
            checkEqual(first.savedCount, 1); checkNil(first.locations.first?.issue)
            _ = try await history.checkNow()
            let unchanged = await library.current()
            checkEqual(unchanged.versions.count, 1)
            try write(file, "second saved draft")
            let second = try await history.checkNow()
            checkEqual(second.savedCount, 2)
            checkEqual(second.storedBytes, Int64("first saved draft".utf8.count + "second saved draft".utf8.count))
            let versions = await library.versions(for: file)
            let restored = try await library.exportVersion(versions[1], into: files)
            checkEqual(try String(contentsOf: restored), "first saved draft")
            checkEqual(try String(contentsOf: file), "second saved draft")
        }
    }
    private static func persistence() async throws {
        try await fixture { library, history, files, data in
            let file = files.appendingPathComponent("Draft.txt")
            try write(file, "first")
            let added = try await history.add([file])
            _ = try await history.checkNow()
            _ = try await history.setEnabled(false)
            try write(file, "paused change")
            _ = try await history.checkNow()
            let paused = await library.current()
            checkEqual(paused.versions.count, 1)
            let reopened = AutomaticHistory(library: library, directory: data, limits: .init(quietSeconds: 0))
            let loaded = try await reopened.load()
            checkFalse(loaded.enabled); checkEqual(loaded.locations.count, 1); checkEqual(loaded.savedCount, 1)
            _ = try await reopened.setEnabled(true)
            _ = try await reopened.checkNow()
            _ = try await reopened.setEnabled(false, locationID: added.locations[0].id)
            try write(file, "individual pause")
            _ = try await reopened.checkNow()
            let onePaused = await library.current()
            checkEqual(onePaused.versions.count, 2)
            _ = try await reopened.remove(added.locations[0].id)
            _ = try await reopened.checkNow()
            let removed = await library.current()
            checkEqual(removed.versions.count, 2)
            let empty = try await reopened.load()
            checkTrue(empty.locations.isEmpty)
        }
    }
    private static func exclusions() async throws {
        try await fixture { library, history, files, data in
            let sensitive = files.appendingPathComponent("Notes.txt")
            try write(sensitive, "password: a sensitive value")
            _ = try await history.add([sensitive])
            let checked = try await history.checkNow()
            checkEqual(checked.savedCount, 0)
            checkTrue(checked.locations[0].issue?.contains("sensitive") == true)
            let link = files.appendingPathComponent("Link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sensitive)
            do { _ = try await history.add([link]); failCheck("A symbolic link must not be selected") } catch {}
            do { _ = try await history.add([data]); failCheck("App data must not be protected") } catch {}
            let excluded = files.appendingPathComponent("Excluded")
            try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
            try write(excluded.appendingPathComponent("Draft.txt"), "ordinary document")
            var settings = IndexSettings(); settings.excludedFolders = [excluded]
            try await library.configureIndexing(settings)
            _ = try await history.add([excluded])
            let skipped = try await history.checkNow()
            checkTrue(skipped.locations.first(where: { $0.url.standardizedFileURL.path == excluded.standardizedFileURL.path })?.issue?.contains("excluded") == true)
            checkEqual(skipped.savedCount, 0)
        }
    }
    private static func retention() async throws {
        try await fixture(limits: .init(versionsPerLocation: 2, quietSeconds: 0)) { library, history, files, data in
            let file = files.appendingPathComponent("Draft.txt")
            try write(file, "manual baseline")
            let initial = try await library.commit(file, message: "Keep this milestone")
            let manualID = initial.versions[0].id
            _ = try await history.add([file])
            _ = try await history.checkNow()
            for text in ["first auto", "second auto", "third auto"] {
                try write(file, text); _ = try await history.checkNow()
            }
            let current = await library.current()
            let protection = await history.current()
            checkEqual(protection.savedCount, 2); checkEqual(current.versions.count, 3)
            checkTrue(current.versions.contains { $0.id == manualID })
            checkTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("Versions/\(manualID.uuidString)/Draft.txt").path))
            checkEqual(try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("Versions").path).count, 3)
            let restored = try await library.exportVersion(current.versions.first(where: { $0.id == manualID })!, into: files)
            checkEqual(try String(contentsOf: restored), "manual baseline")
        }
    }
    private static func budget() async throws {
        try await fixture(limits: .init(versionsPerLocation: 2, totalBytes: 8, locationBytes: 8, quietSeconds: 0)) { library, history, files, _ in
            let a = files.appendingPathComponent("A.txt"), b = files.appendingPathComponent("B.txt")
            try write(a, "aaaa"); try write(b, "bbbb")
            _ = try await history.add([a, b]); _ = try await history.checkNow()
            try write(a, "aaaaaa")
            let full = try await history.checkNow()
            checkEqual(full.storedBytes, 8); checkEqual(full.savedCount, 2)
            checkTrue(full.locations[0].issue?.contains("storage is full") == true)
            let versions = await library.current()
            checkEqual(versions.versions.count, 2)
            checkEqual(try String(contentsOf: a), "aaaaaa")
            let copy = try await library.exportVersion(versions.versions.first(where: { $0.source == a })!, into: files)
            checkEqual(try String(contentsOf: copy), "aaaa")
        }
    }
    private static func failure() async throws {
        try await fixture { library, history, files, data in
            let file = files.appendingPathComponent("Draft.txt")
            try write(file, "first")
            _ = try await history.add([file]); _ = try await history.checkNow()
            // A deterministic manifest failure: copying may succeed, but committing cannot.
            let manifest = data.appendingPathComponent("library.json")
            try FileManager.default.removeItem(at: manifest)
            try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
            try write(file, "new work")
            let checked = try await history.checkNow()
            checkTrue(checked.locations[0].issue != nil)
            checkEqual(checked.savedCount, 1)
            let versions = await library.current()
            checkEqual(versions.versions.count, 1)
            checkEqual(try String(contentsOf: file), "new work")
            checkEqual(try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("Versions").path).count, 1)
            let copy = try await library.exportVersion(versions.versions[0], into: files)
            checkEqual(try String(contentsOf: copy), "first")
        }
    }
    private static func project() async throws {
        try await fixture { library, history, files, _ in
            let project = files.appendingPathComponent("Song.band")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let track = project.appendingPathComponent("track.bin")
            try Data([0, 1, 2]).write(to: track)
            _ = try await history.add([project]); _ = try await history.checkNow()
            try Data([3, 4, 5]).write(to: track)
            _ = try await history.checkNow()
            let versions = await library.versions(for: project)
            let copy = try await library.exportVersion(versions[1], into: files)
            checkEqual(try Data(contentsOf: copy.appendingPathComponent("track.bin")), Data([0, 1, 2]))
            try write(project.appendingPathComponent(".hidden"), "hidden content")
            let skipped = try await history.checkNow()
            checkEqual(skipped.savedCount, 2)
            checkTrue(skipped.locations[0].issue?.contains("hidden") == true)
            try FileManager.default.removeItem(at: project.appendingPathComponent(".hidden"))
            try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("outside"), withDestinationURL: files)
            let linked = try await history.checkNow()
            checkEqual(linked.savedCount, 2)
            checkTrue(linked.locations[0].issue?.contains("symbolic") == true)
        }
    }
}
