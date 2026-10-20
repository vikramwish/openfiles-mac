import Foundation
import Darwin
import CoreGraphics
import ImageIO
import OpenFilesAgent
import OpenFilesCore

enum AgentChecks {
    static func planDecodingAcceptsActions() async throws {
        let json = """
        {"actions":[
          {"kind":"rename","path":"/tmp/OpenFilesAgent/scan.txt","filename":"Travel plan.txt","reason":"matches content"},
          {"kind":"move","path":"/tmp/OpenFilesAgent/scan.txt","folder":"/tmp/OpenFilesAgent/Travel","reason":"topic folder"},
          {"kind":"navigate","folder":"/tmp/OpenFilesAgent/Travel"}
        ]}
        """
        guard let plan = AgentPlanCodec.decode(Data(json.utf8)) else { throw CheckFailure("plan should decode") }
        try expect(plan.actions.count == 3, "expected three actions")
        let rename = plan.actions[0]
        try expect(rename.kind == .rename && rename.name == "Travel plan.txt", "rename decoded with name")
        try expect(rename.source?.path == "/tmp/OpenFilesAgent/scan.txt", "rename source decoded")
        let move = plan.actions[1]
        try expect(move.kind == .move && move.destination?.path == "/tmp/OpenFilesAgent/Travel", "move decoded with destination folder")
        try expect(plan.actions[2].kind == .navigate && plan.actions[2].folder?.path == "/tmp/OpenFilesAgent/Travel", "navigate decoded")
        try expect(plan.ignored.isEmpty, "nothing ignored in a valid plan")
    }

    static func planDecodingRefusesUnknownAndCaps() async throws {
        var actions: [[String: String]] = [
            ["kind": "delete", "path": "/tmp/OpenFilesAgent/scan.txt"],
            ["kind": "rename", "path": "/tmp/OpenFilesAgent/../escape.txt", "filename": "evil.txt"],
            ["kind": "rename", "path": "/tmp/OpenFilesAgent/scan.txt", "filename": "evil.pdf"],
            ["kind": "rename", "path": "/tmp/OpenFilesAgent/scan.txt", "filename": "Travel plan.txt"],
            ["kind": "navigate", "folder": "/tmp/OpenFilesAgent/Travel"],
            ["kind": "navigate", "folder": "/tmp/OpenFilesAgent/Travel"]
        ]
        for index in 0..<60 { actions.append(["kind": "navigate", "folder": "/tmp/OpenFilesAgent/folder-\(index)"]) }
        let data = try JSONSerialization.data(withJSONObject: ["actions": actions])
        guard let plan = AgentPlanCodec.decode(data) else { throw CheckFailure("plan should decode") }
        try expect(plan.actions.count == AgentPlan.actionLimit, "plan is capped at \(AgentPlan.actionLimit) actions, got \(plan.actions.count)")
        try expect(plan.actions.allSatisfy { $0.kind == .navigate || $0.kind == .rename && $0.name == "Travel plan.txt" }, "only valid actions survive")
        try expect(plan.ignored.contains { $0.contains("Unsupported action kind: delete") }, "unknown kind reported")
        try expect(plan.ignored.contains { $0.contains("../escape.txt") == false && $0.contains("evil") }, "invalid names reported")
        try expect(plan.ignored.contains { $0.contains("exceeded") }, "cap reported")
        let duplicates = plan.actions.filter { $0.kind == .navigate && $0.folder?.path == "/tmp/OpenFilesAgent/Travel" }
        try expect(duplicates.count == 1, "duplicate actions deduplicated")
    }

    static func promptBoundaries() async throws {
        var entries: [AgentFileEntry] = []
        for index in 0..<AgentPrompt.entryLimit + 10 {
            entries.append(AgentFileEntry(url: URL(fileURLWithPath: "/tmp/OpenFilesAgent/file-\(index).txt"),
                                          bytes: 120, excerpt: String(repeating: "a\nb", count: 200)))
        }
        let prompt = AgentPrompt.userPrompt(instruction: "rename these files",
                                            currentFolder: URL(fileURLWithPath: "/tmp/OpenFilesAgent"),
                                            selection: URL(fileURLWithPath: "/tmp/OpenFilesAgent/file-1.txt"),
                                            entries: entries, includeExcerpts: true)
        try expect(prompt.contains("Current folder: /tmp/OpenFilesAgent"), "prompt names the current folder")
        try expect(prompt.contains("Selected: /tmp/OpenFilesAgent/file-1.txt"), "prompt names the selection")
        try expect(prompt.contains("file-59.txt"), "prompt includes the last entry within the limit")
        try expect(!prompt.contains("file-60.txt"), "prompt drops entries beyond the limit")
        let excerpt = ": \"" // excerpted entries carry the text in quotes
        try expect(prompt.contains(excerpt), "prompt includes excerpts")
        for line in prompt.split(separator: "\n") {
            if line.contains(": \"") {
                try expect(line.utf8.count <= 1400, "each excerpted line stays bounded")
            }
        }
        let plain = AgentPrompt.userPrompt(instruction: "list files", currentFolder: URL(fileURLWithPath: "/tmp/OpenFilesAgent"),
                                           selection: nil, entries: [AgentFileEntry(url: URL(fileURLWithPath: "/tmp/OpenFilesAgent/a.txt"), bytes: 5, excerpt: "secret")],
                                           includeExcerpts: false)
        try expect(!plain.contains("secret"), "excerpts are omitted when disabled")
        try expect(AgentPlanCodec.validPath("relative/path.txt") == nil, "relative paths are refused")
        try expect(AgentPlanCodec.validPath("/tmp/ok.txt") != nil, "absolute paths are accepted")
    }

    static func clientRequestAndFencedJSON() async throws {
        let transport = MockTransport([Reply(#"{"choices":[{"message":{"content":"```json\n{\"actions\":[]}\n```"}}]}"#)])
        let client = AgentClient(base: URL(string: "https://openrouter.ai/api/v1")!, apiKey: "sk-test", transport: transport)
        let content = try await client.chat(model: "z-ai/glm-5.3", system: "system prompt", user: "user prompt")
        let requests = await transport.recorded()
        try expect(requests.count == 1, "exactly one request")
        let request = requests[0]
        try expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions", "chat completions endpoint")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test", "bearer key attached")
        try expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "JSON content type")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        try expect(body?["model"] as? String == "z-ai/glm-5.3", "model in request body")
        let messages = body?["messages"] as? [[String: Any]]
        try expect(messages?.count == 2 && messages?[0]["role"] as? String == "system", "system message first")
        try expect(request.value(forHTTPHeaderField: "Authorization")?.contains("sk-test") == true, "key only in header")
        guard let data = AgentPlanCodec.extractJSON(in: content), let plan = AgentPlanCodec.decode(data) else {
            throw CheckFailure("fenced JSON should decode")
        }
        try expect(plan.actions.isEmpty, "empty plan from fenced response")
        let keyless = AgentClient(base: URL(string: "http://127.0.0.1:1234/v1")!, apiKey: " ", transport: MockTransport([Reply(#"{"choices":[{"message":{"content":"{\"actions\":[]}"}}]}"#)]))
        _ = try await keyless.chat(model: "local", system: "s", user: "u")
        let recorded = await (keyless.transport as? MockTransport)?.recorded() ?? []
        // Blank keys are treated as absent so local servers never receive an Authorization header.
        try expect(recorded.last?.value(forHTTPHeaderField: "Authorization") == nil, "no authorization header without a key")
    }

    static func clientErrorsAndModels() async throws {
        let client = AgentClient(base: URL(string: "https://openrouter.ai/api/v1")!, apiKey: "sk-test",
                                 transport: MockTransport([Reply(#"{"error":"bad key"}"#, status: 401)]))
        try await expectError({ _ = try await client.chat(model: "m", system: "s", user: "u") }) { error in
            if case AgentClientError.provider(let status, _) = error { return status == 401 }
            return false
        }
        let listing = AgentClient(base: URL(string: "http://127.0.0.1:1234/v1")!, apiKey: nil,
                                  transport: MockTransport([Reply(#"{"data":[{"id":"z-ai/glm-4.5v","architecture":{"input_modalities":["text","image"]}},{"id":"qwen/qwen3.5-9b","architecture":{"input_modalities":["text"]}},{"id":"local-model"}]}"#)]))
        let models = try await listing.models()
        try expect(models.map(\.id) == ["local-model", "qwen/qwen3.5-9b", "z-ai/glm-4.5v"], "models parsed and sorted")
        try expect(models.first { $0.id == "z-ai/glm-4.5v" }?.seesImages == true, "vision capability detected")
        try expect(models.first { $0.id == "qwen/qwen3.5-9b" }?.seesImages == false, "text-only models are flagged")
        try expect(models.first { $0.id == "local-model" }?.seesImages == nil, "unknown modalities stay unknown")
    }

    private struct MoveFixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesAgentMoves-\(UUID())").resolvingSymlinksInPath()
        var files: URL { base.appendingPathComponent("Files") }
        var home: URL { base.appendingPathComponent("Home") }
        var other: URL { base.appendingPathComponent("Other") }
        var data: URL { base.appendingPathComponent("Data") }
        func make() async throws -> FileLibrary {
            let fm = FileManager.default
            try fm.createDirectory(at: files, withIntermediateDirectories: true)
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            try fm.createDirectory(at: other, withIntermediateDirectories: true)
            try "planning notes".write(to: files.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
            try "Password credential material".write(to: files.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
            try "outside file".write(to: other.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
            try fm.createSymbolicLink(at: files.appendingPathComponent("link.txt"), withDestinationURL: files.appendingPathComponent("keep.txt"))
            let library = FileLibrary(directory: data, embeddingFactory: { StubBackend() })
            _ = try await library.load()
            try await library.addRoot(files)
            try await library.addRoot(home)
            return library
        }
        func cleanup() { try? FileManager.default.removeItem(at: base) }
        func realPath(_ url: URL) -> String {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            guard realpath(url.path, &buffer) != nil else { return url.path }
            return String(cString: buffer)
        }
    }

    private actor StubBackend: EmbeddingBackend {
        nonisolated let identifier = "agent-checks"
        func vector(for text: String) -> [Double]? { [1, 0] }
        func queryVector(for text: String) -> [Double]? { [1, 0] }
    }

    static func movePreviewRefusesUnsafeSources() async throws {
        let fixture = MoveFixture(); defer { fixture.cleanup() }
        let library = try await fixture.make()
        let archive = fixture.home.appendingPathComponent("Archive")
        let requests = [
            AgentMoveRequest(source: fixture.files.appendingPathComponent("keep.txt"), folder: archive, reason: "safe"),
            AgentMoveRequest(source: fixture.files.appendingPathComponent("secret.txt"), folder: archive),
            AgentMoveRequest(source: fixture.files.appendingPathComponent("link.txt"), folder: archive),
            AgentMoveRequest(source: fixture.other.appendingPathComponent("outside.txt"), folder: archive),
            AgentMoveRequest(source: fixture.files.appendingPathComponent("keep.txt"), folder: URL(fileURLWithPath: "/Applications")),
            AgentMoveRequest(source: fixture.files.appendingPathComponent("keep.txt"), folder: fixture.files)
        ]
        let preview = try await library.previewAgentMoves(requests, home: fixture.home)
        try expect(preview.suggestions.count == 1, "only the safe move survives, got \(preview.suggestions.count)")
        try expect(preview.suggestions.first?.source.lastPathComponent == "keep.txt", "safe move suggested")
        try expect(preview.suggestions.first?.destination.deletingLastPathComponent().path == archive.path, "move targets the requested folder")
        let reasons = preview.skipped.keys.joined(separator: " · ")
        try expect(reasons.contains("sensitive") || reasons.contains("Sensitive"), "sensitive content refused: \(reasons)")
        try expect(reasons.contains("Symbolic link") || reasons.contains("regular"), "symlink refused: \(reasons)")
        try expect(reasons.contains("Outside personal file scope"), "out-of-scope source refused: \(reasons)")
        try expect(reasons.contains("Destination outside personal folders"), "unsafe destination refused: \(reasons)")
        try expect(reasons.contains("Already organized"), "move into the current folder refused: \(reasons)")
        try expect(!FileManager.default.fileExists(atPath: archive.path), "preview creates no folders")
        try expect(FileManager.default.fileExists(atPath: fixture.files.appendingPathComponent("keep.txt").path), "preview moves nothing")
    }

    static func moveApplyReverifies() async throws {
        let fixture = MoveFixture(); defer { fixture.cleanup() }
        let library = try await fixture.make()
        let archive = fixture.home.appendingPathComponent("Archive")

        // A changed source is refused and nothing moves.
        var preview = try await library.previewAgentMoves([AgentMoveRequest(source: fixture.files.appendingPathComponent("keep.txt"), folder: archive)], home: fixture.home)
        try "changed after preview".write(to: fixture.files.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        var report = try await library.applyAgentMoves(planID: preview.id, selected: Set(preview.suggestions.map(\.id)))
        try expect(report.moved == 0 && !report.errors.isEmpty, "changed source is refused")
        try expect(FileManager.default.fileExists(atPath: fixture.files.appendingPathComponent("keep.txt").path), "source retained")

        // A valid move copies, verifies and removes the original.
        try "planning notes v2".write(to: fixture.files.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        preview = try await library.previewAgentMoves([AgentMoveRequest(source: fixture.files.appendingPathComponent("keep.txt"), folder: archive)], home: fixture.home)
        report = try await library.applyAgentMoves(planID: preview.id, selected: Set(preview.suggestions.map(\.id)))
        try expect(report.moved == 1 && report.errors.isEmpty, "valid move applied: \(report.errors)")
        let destination = preview.suggestions.first!.destination
        try expect(try String(contentsOf: destination, encoding: .utf8) == "planning notes v2", "moved bytes match")
        try expect(!FileManager.default.fileExists(atPath: fixture.files.appendingPathComponent("keep.txt").path), "original removed after verified copy")
        let state = await library.current()
        try expect(state.files.contains { $0.url.path == fixture.realPath(destination) }, "index records the moved file at its stable path")

        // An existing destination is never replaced; the move takes a suffixed name.
        try "keep this".write(to: fixture.files.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try "existing copy".write(to: archive.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        preview = try await library.previewAgentMoves([AgentMoveRequest(source: fixture.files.appendingPathComponent("keep.txt"), folder: archive)], home: fixture.home)
        try expect(preview.suggestions.first?.destination.lastPathComponent == "keep (2).txt", "collision takes a suffixed name")
        report = try await library.applyAgentMoves(planID: preview.id, selected: Set(preview.suggestions.map(\.id)))
        try expect(report.moved == 1, "collision move applied")
        try expect(try String(contentsOf: archive.appendingPathComponent("keep.txt"), encoding: .utf8) == "existing copy", "existing file untouched")
        try expect(try String(contentsOf: archive.appendingPathComponent("keep (2).txt"), encoding: .utf8) == "keep this", "new copy holds the moved bytes")
    }

    static func navigatePathAlias() async throws {
        let json = """
        {"actions":[
          {"kind":"navigate","path":"/tmp/OpenFilesAgent/Travel"},
          {"kind":"navigate","folder":"/tmp/OpenFilesAgent/Travel"}
        ]}
        """
        guard let plan = AgentPlanCodec.decode(Data(json.utf8)) else { throw CheckFailure("plan should decode") }
        try expect(plan.actions.count == 1, "path and folder navigate forms deduplicate, got \(plan.actions.count)")
        try expect(plan.actions.first?.kind == .navigate && plan.actions.first?.folder?.path == "/tmp/OpenFilesAgent/Travel", "path accepted as the navigate folder")
        try expect(plan.ignored.isEmpty, "the alias form is not reported as ignored")
    }

    static func availabilityFlagsInapplicableActions() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesAgentAvailability-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let files = base.appendingPathComponent("Files")
        let home = base.appendingPathComponent("Home")
        let fm = FileManager.default
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try "notes".write(to: files.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try "credentials".write(to: files.appendingPathComponent("passwords.txt"), atomically: true, encoding: .utf8)

        // Advisory checks mirror the authoritative guards: missing, sensitive, out of scope, lost folder.
        let missing = AgentAction(kind: .rename, source: files.appendingPathComponent("missing.txt"), name: "New name.txt")
        try expect(missing.availability(home: home, roots: [files]) == "File not found", "missing source is flagged")
        let sensitive = AgentAction(kind: .rename, source: files.appendingPathComponent("passwords.txt"), name: "New name.txt")
        try expect(sensitive.availability(home: home, roots: [files]) == "Potentially sensitive", "sensitive name is flagged")
        let outside = AgentAction(kind: .move, source: files.appendingPathComponent("keep.txt"), destination: URL(fileURLWithPath: "/Applications"))
        try expect(outside.availability(home: home, roots: [files]) == "Destination outside personal folders", "out-of-scope destination is flagged")
        let lostFolder = AgentAction(kind: .navigate, folder: files.appendingPathComponent("Nowhere"))
        try expect(lostFolder.availability(home: home, roots: [files]) == "Folder not found", "missing navigate folder is flagged")
        let goodRename = AgentAction(kind: .rename, source: files.appendingPathComponent("keep.txt"), name: "New name.txt")
        try expect(goodRename.availability(home: home, roots: [files]) == nil, "valid rename is available")
        // Folders inside the user's scope do not need to exist yet; the move creates them when applied.
        let goodMove = AgentAction(kind: .move, source: files.appendingPathComponent("keep.txt"), destination: home.appendingPathComponent("Archive"))
        try expect(goodMove.availability(home: home, roots: [files]) == nil, "a move to a folder that will be created stays available")
        let goodNavigate = AgentAction(kind: .navigate, folder: home)
        try expect(goodNavigate.availability(home: home, roots: [files]) == nil, "valid navigate is available")
    }

    static func clientSendsMultimodalParts() async throws {
        let transport = MockTransport([Reply(#"{"choices":[{"message":{"content":"{\"actions\":[]}"}}]}"#)])
        let client = AgentClient(base: URL(string: "https://openrouter.ai/api/v1")!, apiKey: "sk-test", transport: transport)
        _ = try await client.chat(model: "vision-model", system: "s", parts: [
            .text("rename these screenshots"),
            .imageData(mediaType: "image/jpeg", base64: "QUJD")
        ])
        let requests = await transport.recorded()
        try expect(requests.count == 1, "one request")
        let body = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        let messages = body?["messages"] as? [[String: Any]]
        try expect(messages?.count == 2, "system plus user message")
        try expect(messages?[0]["content"] as? String == "s", "system content stays plain text")
        let parts = messages?[1]["content"] as? [[String: Any]]
        try expect(parts?.count == 2, "two content parts")
        try expect(parts?[0]["type"] as? String == "text" && parts?[0]["text"] as? String == "rename these screenshots", "text part first")
        let image = parts?[1]
        try expect(image?["type"] as? String == "image_url", "image part second")
        let url = ((image?["image_url"] as? [String: Any])?["url"] as? String) ?? ""
        try expect(url == "data:image/jpeg;base64,QUJD", "data URL built from the preview")
    }

    static func imagePreviewDownscales() async throws {
        // Draw a large synthetic JPEG with CoreGraphics, then verify the bounded preview.
        let width = 2000, height = 1200
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw CheckFailure("test image could not be drawn") }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesAgentPreview-\(UUID()).jpg").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let container = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(container, "public.jpeg" as CFString, 1, nil) else {
            throw CheckFailure("destination failed")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CheckFailure("encoding failed") }
        let original = container as Data
        try original.write(to: URL(fileURLWithPath: path))

        try expect(AgentImagePreview.isVisionCandidate(path: path, bytes: Int64(original.count)), "recognized image candidate")
        try expect(!AgentImagePreview.isVisionCandidate(path: path.replacingOccurrences(of: ".jpg", with: ".txt"), bytes: Int64(original.count)), "non-image extensions are refused")
        try expect(!AgentImagePreview.isVisionCandidate(path: path, bytes: 20 * 1024 * 1024), "oversized files are refused")
        guard let preview = AgentImagePreview.downscale(path: path) else { throw CheckFailure("preview should downscale") }
        try expect(preview.mediaType == "image/jpeg", "JPEG media type")
        try expect(preview.base64.hasPrefix("/9j/"), "JPEG magic bytes after downscale")
        let decoded = Data(base64Encoded: preview.base64) ?? Data()
        try expect(decoded.count < original.count, "preview is smaller than the original")
        try expect(decoded.count < 400_000, "preview stays bounded")
    }

    static func collectionCodecAcceptsOnlyCandidates() async throws {
        let prompt = AgentPrompt.collectionUserPrompt(title: "Kyoto trip", entries: [
            AgentFileEntry(url: URL(fileURLWithPath: "/tmp/OpenFilesAgent/kyoto-notes.txt"), bytes: 131, excerpt: "Kyoto travel plan"),
            AgentFileEntry(url: URL(fileURLWithPath: "/tmp/OpenFilesAgent/budget.txt"), bytes: 134)
        ])
        try expect(prompt.contains("Collection: Kyoto trip"), "prompt names the collection")
        try expect(prompt.contains("/tmp/OpenFilesAgent/kyoto-notes.txt (131 bytes): \"Kyoto travel plan\""), "excerpts ride along with candidates")
        try expect(prompt.contains("/tmp/OpenFilesAgent/budget.txt (134 bytes)"), "all candidates listed")

        let candidates = [URL(fileURLWithPath: "/tmp/OpenFilesAgent/kyoto-notes.txt"),
                          URL(fileURLWithPath: "/tmp/OpenFilesAgent/budget.txt")]
        let json = """
        {"members":[
          {"path":"/tmp/OpenFilesAgent/kyoto-notes.txt","reason":"Kyoto planning notes"},
          {"path":"/tmp/OpenFilesAgent/invented.txt","reason":"not a candidate"},
          {"path":"/tmp/OpenFilesAgent/kyoto-notes.txt","reason":"duplicate"},
          {"path":"/tmp/OpenFilesAgent/budget.txt","reason":"trip budget"}
        ]}
        """
        let decoded = AgentCollectionCodec.decode(Data(json.utf8), candidates: candidates)
        try expect(decoded.members.count == 2, "only supplied candidates survive, got \(decoded.members.count)")
        try expect(decoded.members.allSatisfy { candidates.contains($0.url) }, "no invented paths")
        try expect(decoded.members.first?.reason == "Kyoto planning notes", "reasons are kept")
        try expect(decoded.ignored.contains { $0.contains("not among the candidates") }, "invented path reported")
        var many: [[String: String]] = []
        for index in 0..<40 { many.append(["path": "/tmp/OpenFilesAgent/kyoto-notes.txt", "reason": "r\(index)"]) }
        // Different reasons would pass the dedupe only by path; all identical paths collapse to one member.
        let collapsed = AgentCollectionCodec.decode(Data(try JSONSerialization.data(withJSONObject: ["members": many])), candidates: candidates)
        try expect(collapsed.members.count == 1, "duplicates collapse")
    }

    static func agentRenameVerifiesLargeFiles() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesAgentBigRename-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let files = base.appendingPathComponent("Files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let library = FileLibrary(directory: base.appendingPathComponent("Data"), embeddingFactory: { StubBackend() })
        _ = try await library.load()
        try await library.addRoot(files)

        // A file past the 5 MB suggestion cap still renames through the verified agent path.
        let big = files.appendingPathComponent("Screenshot large.png")
        let payload = Data(count: 6 * 1024 * 1024)
        try payload.write(to: big)
        let preview = try await library.previewAgentRename(big)
        try expect(preview.suggestions.isEmpty, "agent previews carry no ranked suggestions")
        let result = try await library.applyRename(previewID: preview.id, name: "Descriptive screenshot.png")
        try expect(result.destination.lastPathComponent == "Descriptive screenshot.png", "renamed to the reviewed name")
        try expect(!FileManager.default.fileExists(atPath: big.path), "original removed after the verified copy")
        try expect((try? Data(contentsOf: result.destination))?.count == payload.count, "bytes preserved")

        // Sensitive names are still refused.
        let sensitive = files.appendingPathComponent("passwords.txt")
        try "credentials".write(to: sensitive, atomically: true, encoding: .utf8)
        try await expectError({ _ = try await library.previewAgentRename(sensitive) }) { error in
            error.localizedDescription.contains("sensitive")
        }
    }

    static func renameAvailabilityFlagsCollisions() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesAgentCollision-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let files = base.appendingPathComponent("Files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try "keep".write(to: files.appendingPathComponent("existing name.txt"), atomically: true, encoding: .utf8)
        try "source".write(to: files.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        let action = AgentAction(kind: .rename, source: files.appendingPathComponent("source.txt"), name: "Existing Name.TXT")
        try expect(action.availability(home: base, roots: [files]) == "A file with that name already exists",
                  "collisions are flagged case-insensitively before approval")
        let clear = AgentAction(kind: .rename, source: files.appendingPathComponent("source.txt"), name: "Fresh name.txt")
        try expect(clear.availability(home: base, roots: [files]) == nil, "clear names stay available")
    }
}
