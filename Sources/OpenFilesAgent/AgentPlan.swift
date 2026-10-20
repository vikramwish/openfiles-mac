import Foundation
import OpenFilesCore

/// One action the agent proposes. The app mediates every change; the agent never touches files itself.
public struct AgentAction: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case rename, move, navigate
    }
    public let id: UUID
    public let kind: Kind
    /// File to rename or move.
    public let source: URL?
    /// Proposed filename for a rename. Validated against the same rules as manual renames.
    public let name: String?
    /// Destination folder for a move. The file keeps its name inside this folder.
    public let destination: URL?
    /// Folder the browser should open for a navigate action.
    public let folder: URL?
    public let reason: String
    public init(id: UUID = UUID(), kind: Kind, source: URL? = nil, name: String? = nil, destination: URL? = nil, folder: URL? = nil, reason: String = "") {
        self.id = id; self.kind = kind; self.source = source; self.name = name
        self.destination = destination; self.folder = folder; self.reason = reason
    }

    /// nil when the action looks applicable, otherwise a short reason for the panel. Advisory only:
    /// every guard still runs authoritatively when the approved action is applied.
    public func availability(home: URL, roots: [URL]) -> String? {
        let fm = FileManager.default
        switch kind {
        case .rename, .move:
            guard let source else { return "No file referenced" }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return "File not found" }
            guard !FileRules.sensitive(source.lastPathComponent) else { return "Potentially sensitive" }
            if kind == .move {
                guard let destination else { return "No destination folder" }
                // Folders inside the user's scope can be created during the move; anything else is refused later.
                let scope = [home.resolvingSymlinksInPath().standardizedFileURL] + roots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
                guard scope.contains(where: { FileRules.contains($0, destination) }) else { return "Destination outside personal folders" }
            }
        case .navigate:
            guard let folder else { return "No folder referenced" }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return "Folder not found" }
        }
        return nil
    }
}

public struct AgentPlan: Sendable, Equatable {
    public static let actionLimit = 12
    public var actions: [AgentAction]
    /// Actions the decoder refused, with the reason. Shown in the panel; never silent.
    public var ignored: [String]
    public init(actions: [AgentAction] = [], ignored: [String] = []) {
        self.actions = actions; self.ignored = ignored
    }
}

public enum AgentPlanCodec {
    /// Absolute paths only, no parent traversal, no control characters.
    public static func validPath(_ raw: String) -> URL? {
        guard raw.hasPrefix("/"), raw.utf8.count <= 1024,
              !raw.contains("\0"),
              !raw.components(separatedBy: "/").contains("..") else { return nil }
        return URL(fileURLWithPath: raw)
    }

    /// Models sometimes wrap JSON in prose or markdown fences. Slice out the object defensively.
    public static func extractJSON(in text: String) -> Data? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            if let start = trimmed.firstIndex(where: \.isNewline) {
                trimmed = String(trimmed[trimmed.index(after: start)...])
            }
            if let fence = trimmed.range(of: "```", options: .backwards) {
                trimmed = String(trimmed[..<fence.lowerBound])
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first < last else {
            return trimmed.utf8.count < 65536 ? Data(trimmed.utf8) : nil
        }
        let slice = String(trimmed[first...last])
        guard slice.utf8.count < 65536 else { return nil }
        return Data(slice.utf8)
    }

    /// Strict decode: unknown kinds, invented paths, invalid names and duplicates are refused, never guessed.
    public static func decode(_ data: Data) -> AgentPlan? {
        struct PlanDTO: Decodable {
            struct ActionDTO: Decodable {
                let kind: String?
                let path: String?
                let filename: String?
                let folder: String?
                let reason: String?
            }
            let actions: [ActionDTO]?
        }
        guard let dto = try? JSONDecoder().decode(PlanDTO.self, from: data) else { return nil }
        var plan = AgentPlan()
        var seen = Set<String>()
        for item in dto.actions ?? [] {
            let reason = String((item.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
            func ignore(_ why: String) { plan.ignored.append(why) }
            guard plan.actions.count < AgentPlan.actionLimit else { ignore("Plan exceeded \(AgentPlan.actionLimit) actions"); break }
            guard let kind = item.kind?.lowercased().trimmingCharacters(in: .whitespaces) else { ignore("Action without a kind"); continue }
            let path = item.path.map { validPath($0) } ?? nil
            let folder = item.folder.map { validPath($0) } ?? nil
            switch kind {
            case "rename":
                guard let source = path, let name = item.filename?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { ignore("Rename without a file or filename"); continue }
                guard (try? RenameNames.validate(name, source: source)) != nil else { ignore("Proposed name was refused: \(name)"); continue }
                guard seen.insert("rename|\(source.path)|\(name.lowercased())").inserted else { continue }
                plan.actions.append(AgentAction(kind: .rename, source: source, name: name, reason: reason))
            case "move":
                guard let source = path, let destination = folder else { ignore("Move without a file or destination folder"); continue }
                guard seen.insert("move|\(source.path)|\(destination.path)").inserted else { continue }
                plan.actions.append(AgentAction(kind: .move, source: source, destination: destination, reason: reason))
            case "navigate":
                // Some models put the folder in "path" (observed with local Qwen); accept it rather
                // than refusing an otherwise clear action, and dedupe against the "folder" form.
                guard let target = folder ?? path else { ignore("Navigate without a folder"); continue }
                guard seen.insert("navigate|\(target.path)").inserted else { continue }
                plan.actions.append(AgentAction(kind: .navigate, folder: target, reason: reason))
            default:
                ignore("Unsupported action kind: \(kind)")
            }
        }
        return plan
    }
}

/// One visible file handed to the model as context. The app filters sensitive entries before building the prompt.
public struct AgentFileEntry: Sendable, Equatable {
    public let url: URL
    public let isFolder: Bool
    public let bytes: Int64
    public let excerpt: String?
    public init(url: URL, isFolder: Bool = false, bytes: Int64 = 0, excerpt: String? = nil) {
        self.url = url; self.isFolder = isFolder; self.bytes = bytes; self.excerpt = excerpt
    }
}

public enum AgentPrompt {
    public static let entryLimit = 60
    public static let excerptLimit = 400

    public static func systemPrompt() -> String {
        """
        You are the OpenFiles planning assistant. The user browses files on their Mac and asks for help. Propose file actions as strict JSON. Allowed action kinds: "rename" (path of an existing file and a better filename with the same extension), "move" (path of an existing file and a destination folder to move it into), "navigate" (a folder path to open in the browser). Rules: only reference paths that appear in the context; never invent paths; keep the original extension on renames; never propose actions on sensitive files; propose at most 12 actions; prefer a few high-quality actions. Respond with ONLY a JSON object like {"actions":[{"kind":"rename","path":"/absolute/path.txt","filename":"New name.txt","reason":"short explanation"}]} with no prose and no markdown fences.
        """
    }

    /// Bounded context: paths, sizes, and optional short excerpts. File contents never appear beyond these excerpts.
    public static func userPrompt(instruction: String, currentFolder: URL, selection: URL?, entries: [AgentFileEntry], includeExcerpts: Bool) -> String {
        var lines: [String] = []
        lines.append("Current folder: \(currentFolder.path)")
        if let selection { lines.append("Selected: \(selection.path)") }
        lines.append("Visible files:")
        for entry in entries.prefix(entryLimit) {
            let kind = entry.isFolder ? "folder" : "\(entry.bytes) bytes"
            if includeExcerpts, let excerpt = entry.excerpt, !excerpt.isEmpty {
                let bounded = String(excerpt.prefix(excerptLimit)).replacingOccurrences(of: "\n", with: " ")
                lines.append("\(entry.url.path) (\(kind)): \"\(bounded)\"")
            } else {
                lines.append("\(entry.url.path) (\(kind))")
            }
        }
        lines.append("The user asks: \(instruction)")
        return lines.joined(separator: "\n")
    }
}
