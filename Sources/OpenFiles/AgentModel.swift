import Foundation
import OpenFilesCore
import OpenFilesAgent

/// Agent request building and reviewed application. The agent only proposes; every change
/// goes through the same preview → approval → verified apply flows used elsewhere in the app.
@MainActor
extension AppModel {
    var agentClient: AgentClient? {
        guard let base = URL(string: agentEndpointBase.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = base.scheme, ["http", "https"].contains(scheme), base.host != nil else { return nil }
        return AgentClient(base: base, apiKey: AgentKeychain.load())
    }

    /// Sensitive names are filtered before anything is sent to the model service.
    func agentEntries() -> [AgentFileEntry] {
        Array(browserItems
            .filter { !$0.sensitive && !FileRules.sensitive($0.name) }
            .prefix(AgentPrompt.entryLimit)
            .map { AgentFileEntry(url: $0.url, isFolder: $0.isFolder, bytes: $0.size, excerpt: nil) })
    }

    /// Advisory per-action check shown in the panel before approval. The authoritative
    /// guards still run when an approved action is applied.
    func agentAvailability(_ action: AgentAction) -> String? {
        action.availability(home: FileManager.default.homeDirectoryForCurrentUser, roots: state.roots)
    }

    func requestAgentPlan(_ instruction: String) async {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        guard let client = agentClient else {
            agentError = "Enter a valid model endpoint, for example https://openrouter.ai/api/v1"
            return
        }
        agentBusy = true; agentError = nil; agentOutcomes = []; agentPlan = nil; agentSelection = []
        defer { agentBusy = false }
        var entries = agentEntries()
        if agentIncludeExcerpts {
            let candidates = entries
                .filter { !$0.isFolder && $0.bytes <= 64 * 1024 && FileRules.textExtensions.contains($0.url.pathExtension.lowercased()) }
                .prefix(20).map(\.url)
            let excerpts = await Task.detached(priority: .utility) { () -> [URL: String] in
                var result: [URL: String] = [:]
                for url in candidates {
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    let excerpt = String(text.prefix(AgentPrompt.excerptLimit))
                    if !FileRules.sensitive(excerpt) { result[url] = excerpt }
                }
                return result
            }.value
            entries = entries.map { entry in
                guard let excerpt = excerpts[entry.url] else { return entry }
                return AgentFileEntry(url: entry.url, isFolder: entry.isFolder, bytes: entry.bytes, excerpt: excerpt)
            }
        }
        var parts: [AgentContentPart] = []
        if agentIncludeExcerpts {
            // Downscaled previews of up to 4 image files let the model rename screenshots from what they show.
            let imageCandidates = entries
                .filter { AgentImagePreview.isVisionCandidate(path: $0.url.path, bytes: $0.bytes) }
                .prefix(4).map(\.url)
            if !imageCandidates.isEmpty {
                let previews = await Task.detached(priority: .utility) { () -> [AgentContentPart] in
                    var result: [AgentContentPart] = []
                    for url in imageCandidates {
                        if let preview = AgentImagePreview.downscale(path: url.path) {
                            result.append(.imageData(mediaType: preview.mediaType, base64: preview.base64))
                        }
                    }
                    return result
                }.value
                parts = previews
            }
        }
        let prompt = AgentPrompt.userPrompt(instruction: instruction, currentFolder: currentFolder, selection: selectedURL, entries: entries, includeExcerpts: agentIncludeExcerpts)
        parts.insert(.text(prompt), at: 0)
        do {
            let content = try await client.chat(model: agentModel, system: AgentPrompt.systemPrompt(), parts: parts)
            guard let data = AgentPlanCodec.extractJSON(in: content), let plan = AgentPlanCodec.decode(data) else {
                agentError = "The model did not return a usable plan. Try rephrasing the request."
                return
            }
            agentPlan = plan
            // Only applicable actions start selected; unavailable rows stay visible with their reason.
            let available = plan.actions.filter { agentAvailability($0) == nil }
            agentSelection = Set(available.map(\.id))
            let unavailable = plan.actions.count - available.count
            status = "Hermes proposed \(plan.actions.count) action\(plan.actions.count == 1 ? "" : "s").\(unavailable > 0 ? " \(unavailable) cannot be applied as proposed." : "") Review and approve them."
        } catch { agentError = error.localizedDescription }
    }

    func applyAgentPlan() async {
        guard let plan = agentPlan else { return }
        agentBusy = true; agentError = nil
        defer { agentBusy = false }
        var outcomes: [String] = []
        var moves: [AgentMoveRequest] = []
        for action in plan.actions where agentSelection.contains(action.id) {
            switch action.kind {
            case .rename:
                guard let source = action.source, let name = action.name else { continue }
                do {
                    // The preview re-reads and re-verifies the file; applyRename re-checks stamp, digest and collisions.
                    let preview = try await library.previewRename(source)
                    let result = try await library.applyRename(previewID: preview.id, name: name)
                    if let warning = result.indexWarning { outcomes.append(warning) }
                    outcomes.append("Renamed \(source.lastPathComponent) to \(result.destination.lastPathComponent)")
                } catch { outcomes.append("Rename of \(source.lastPathComponent) failed: \(error.localizedDescription)") }
            case .move:
                guard let source = action.source, let destination = action.destination else { continue }
                moves.append(AgentMoveRequest(source: source, folder: destination, reason: action.reason))
            case .navigate:
                guard let folder = action.folder else { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    outcomes.append("Folder to open is unavailable: \(folder.path)")
                    continue
                }
                section = .files
                navigate(to: folder)
                outcomes.append("Opened \(folder.path)")
            }
        }
        if !moves.isEmpty {
            do {
                let preview = try await library.previewAgentMoves(moves, home: FileManager.default.homeDirectoryForCurrentUser)
                for (reason, count) in preview.skipped.sorted(by: { $0.key < $1.key }) {
                    outcomes.append("\(count) move\(count == 1 ? "" : "s") refused: \(reason)")
                }
                if !preview.suggestions.isEmpty {
                    let report = try await library.applyAgentMoves(planID: preview.id, selected: Set(preview.suggestions.map(\.id)))
                    outcomes.append("Moved \(report.moved) file\(report.moved == 1 ? "" : "s")")
                    outcomes += report.errors
                }
            } catch { outcomes.append("Moves failed: \(error.localizedDescription)") }
        }
        agentOutcomes = outcomes
        agentPlan = nil; agentSelection = []
        state = await library.current()
        refreshAfterAgentChanges(select: selectedURL)
        status = outcomes.isEmpty ? "No actions were applied." : "Applied the approved actions. Nothing changed without your review."
    }

    func testAgentConnection() async {
        guard let client = agentClient else { agentConnection = "Enter a valid model endpoint first."; return }
        agentConnection = "Contacting \(agentEndpointBase)…"
        do {
            let models = try await client.models()
            agentModelOptions = models
            agentConnection = models.isEmpty ? "Connected, but the service listed no models." : "Connected · \(models.count) models listed."
        } catch {
            agentModelOptions = []
            agentConnection = error.localizedDescription
        }
    }

    /// Reads the user's existing OPENROUTER_API_KEY from the Hermes configuration. The key is
    /// copied into Keychain and never displayed or logged.
    func importAgentKeyFromHermes() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [home + "/.hermes/.env"]
        if let profiles = try? FileManager.default.contentsOfDirectory(atPath: home + "/.hermes/profiles") {
            paths += profiles.sorted().map { home + "/.hermes/profiles/\($0)/.env" }
        }
        for path in paths {
            guard let key = Self.openRouterKey(at: path) else { continue }
            do {
                try AgentKeychain.save(key)
                agentHasKey = true
                agentError = nil
                agentConnection = "API key imported from Hermes and saved in Keychain."
                return
            } catch {
                agentError = "Could not save the key in Keychain: \(error.localizedDescription)"
                return
            }
        }
        agentError = "No OPENROUTER_API_KEY was found in the Hermes configuration (~/.hermes)."
    }

    func clearAgentKey() {
        AgentKeychain.delete()
        agentHasKey = false
        agentConnection = "The saved API key was removed."
    }

    private nonisolated static func openRouterKey(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), data.count <= 1_000_000,
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let body = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst(7)) : trimmed
            guard body.hasPrefix("OPENROUTER_API_KEY=") else { continue }
            let key = body.dropFirst("OPENROUTER_API_KEY=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\r"))
            if !key.isEmpty { return String(key) }
        }
        return nil
    }
}
