import Foundation
import CryptoKit
import Darwin

public struct DeveloperCleanupItem: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let category: String
    public let evidence: String
    public let recovery: String
    public let bytes: Int64
    public let entries: Int
    public let canTrash: Bool
    public let complete: Bool
    fileprivate let fingerprint: String?
}
public struct DeveloperCleanupReview: Sendable {
    public let id: UUID
    public let scope: URL
    public var items: [DeveloperCleanupItem] = []
    public var visited = 0
    public var skipped = 0
    public var limited = false
    public var selectableBytes: Int64 { items.filter(\.canTrash).reduce(0) { $0 + $1.bytes } }
}
private struct DeveloperCategory {
    let name: String
    let evidence: String
    let recovery: String
    let removable: Bool
}
private struct DeveloperTree {
    let fingerprint: String
    let bytes: Int64
    let entries: Int
}

/// Explicit, bounded scans of generated developer artifacts, independent of semantic indexing.
/// No shell commands, package imports, package-manager execution, or symlink traversal.
public actor DeveloperCleanupService {
    private let appData: URL
    private let trash: any CleanupTrash
    private var current: DeveloperCleanupReview?
    private var protected: [URL] = []
    private var scanRoots: [URL] = []
    public init(directory: URL, trash: any CleanupTrash = SystemCleanupTrash()) {
        appData = directory.canonical; self.trash = trash
    }
    public func preview(scope: URL, excluding: [URL] = [], discoveryLimit: Int = 50_000, treeLimit: Int = 200_000, scopes: [URL]? = nil) throws -> DeveloperCleanupReview {
        current = nil
        let scope = scope.canonical
        scanRoots = MacScanScopes.reduce(scopes ?? [scope])
        for root in scanRoots { try validateScope(root) }
        protected = excluding.map(\.canonical) + [appData]
        var review = DeveloperCleanupReview(id: UUID(), scope: scope)
        let devices = Set(try scanRoots.map { try info($0).st_dev })
        var stack = Array(scanRoots.reversed())
        while let discovered = stack.popLast() {
            let url = discovered.standardizedFileURL
            try Task.checkCancellation()
            guard review.visited < min(50_000, max(1, discoveryLimit)), review.items.count < 200 else { review.limited = true; break }
            review.visited += 1
            guard !protected.contains(where: { syncContains($0, url) }), let info = try? info(url), !isLink(info), devices.contains(info.st_dev), !cloud(url) else { review.skipped += 1; continue }
            if let category = classify(url, info: info) {
                let overlaps = protected.contains { syncContains(url, $0) }
                let measured = overlaps ? nil : try? measure(url, scope: scope, limit: min(200_000, max(1, treeLimit)))
                try Task.checkCancellation()
                let complete = measured != nil
                review.items.append(DeveloperCleanupItem(id: UUID(), url: url, category: category.name,
                    evidence: category.evidence + (overlaps ? " Contains a protected location; inspection only." : !complete ? " Could not completely measure this item; inspection only." : ""),
                    recovery: category.recovery, bytes: measured?.bytes ?? 0, entries: measured?.entries ?? 0,
                    canTrash: category.removable && complete && !overlaps, complete: complete, fingerprint: measured?.fingerprint))
                if !complete { review.limited = true }
                continue // Never offer overlapping child artifacts, and never explore VM contents.
            }
            guard isDirectory(info), shouldExplore(url, scope: scope) else { continue }
            do {
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                stack.append(contentsOf: children.sorted { $0.path > $1.path })
            } catch { review.skipped += 1 }
        }
        review.items.sort { $0.bytes == $1.bytes ? $0.url.path < $1.url.path : $0.bytes > $1.bytes }
        try Task.checkCancellation()
        current = review
        return review
    }
    public func apply(reviewID: UUID, selected: Set<UUID>, workloadsStopped: Bool, excluding: [URL] = []) throws -> CleanupResult {
        guard workloadsStopped else { throw OpenFilesError.message("Stop interpreters, development servers and builds before moving their dependencies or caches.") }
        guard let review = current, review.id == reviewID, !selected.isEmpty,
              selected.isSubset(of: Set(review.items.filter(\.canTrash).map(\.id))) else { throw OpenFilesError.message("Select eligible items from a current developer review. VM disks and shared runtimes are inspection-only.") }
        protected.append(contentsOf: excluding.map(\.canonical))
        let files = review.items.filter { selected.contains($0.id) }
        func verify(_ file: DeveloperCleanupItem) throws {
            guard !protected.contains(where: { syncContains(file.url, $0) || syncContains($0, file.url) }),
                  let info = try? info(file.url), classify(file.url, info: info)?.removable == true,
                  try measure(file.url, scope: review.scope, limit: 200_000).fingerprint == file.fingerprint else {
                throw OpenFilesError.message("\(file.url.lastPathComponent) changed, became protected, or cannot be completely verified. Scan again.")
            }
        }
        for file in files { try Task.checkCancellation(); try verify(file) }
        let journal = appData.appendingPathComponent("Cleanup", isDirectory: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let receiptURL = journal.appendingPathComponent("developer-\(review.id).json")
        var result = CleanupResult()
        func save() throws {
            try JSONEncoder().encode(result.receipts).write(to: receiptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
        }
        try save()
        current = nil
        for file in files {
            do {
                try Task.checkCancellation(); try verify(file); try Task.checkCancellation()
                let destination = try trash.moveToTrash(file.url)
                result.receipts.append(CleanupReceipt(id: UUID(), original: file.url, trashed: destination, date: Date()))
                do { try save() } catch { result.errors.append("Moved to Trash but receipt could not be saved: \(file.url.path)"); break }
            } catch { result.errors.append("\(file.url.path): \(error.localizedDescription)") }
        }
        return result
    }
    private func classify(_ url: URL, info: stat) -> DeveloperCategory? {
        let name = url.lastPathComponent, parent = url.deletingLastPathComponent(), directory = isDirectory(info)
        let fm = FileManager.default
        func marker(_ name: String, in folder: URL? = nil) -> Bool {
            let path = (folder ?? parent).appendingPathComponent(name)
            guard let value = try? self.info(path) else { return false }
            return value.st_mode & S_IFMT == S_IFREG && value.st_size <= 10 * 1024 * 1024
        }
        func item(_ title: String, _ detail: String, _ recovery: String, _ removable: Bool = true) -> DeveloperCategory {
            DeveloperCategory(name: title, evidence: detail, recovery: recovery, removable: removable)
        }
        let ext = url.pathExtension.lowercased()
        if ["utm", "pvm", "vmwarevm", "vbox", "vdi", "vmdk", "qcow2", "vhd", "vhdx", "hdd"].contains(ext) || name == "Docker.raw" || name == "Docker.qcow2" {
            return item("Virtual machine / container disk", "May contain entire operating systems, databases and unique files. Allocated size can be smaller than its virtual capacity.", "Inspect in the owning VM or container app. Back up or export needed data there; this item cannot be trashed here.", false)
        }
        guard directory else { return nil }
        if [".docker", ".colima", ".orbstack"].contains(name) {
            return item("Container / VM storage", "May include persistent volumes, local databases, VM state and credentials. It is not a disposable cache.", "Inspect disk usage and remove unused resources in the owning tool. Volumes and VM state cannot be trashed here.", false)
        }
        if url.path.hasSuffix("/Library/Developer/CoreSimulator/Devices") {
            return item("Simulator devices", "Contains simulator operating-system and app data, including local development state.", "Manage simulators in Xcode. Device data is inspection-only here.", false)
        }
        if name == "node_modules", !marker("package.json") {
            return item("Shared Node libraries", "No adjacent project manifest was found. This may be a global runtime's package directory.", "Inspect packages with the owning Node installation or package manager. Shared libraries are inspection-only here.", false)
        }
        if name == "node_modules", marker("package.json") {
            let locked = ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb"].contains { marker($0) }
            return item("Node dependencies", locked ? "Dependency folder beside a package manifest and lockfile. Local patches or linked workspace dependencies still need review." : "Dependency folder with no recognized lockfile. Exact package versions may be unrecoverable; inspection only.", "Reinstall with this project's package manager and lockfile. Preserve local package patches first; installation may need network access and run package scripts.", locked)
        }
        if marker("pyvenv.cfg", in: url) {
            let manifest = ["requirements.txt", "pyproject.toml", "uv.lock", "poetry.lock", "Pipfile.lock", "environment.yml"].contains { marker($0) }
            return item("Python virtual environment", manifest ? "Isolated Python environment beside dependency metadata. The manifest may not describe every manually installed package." : "Isolated Python environment without nearby dependency metadata. Installed packages may not be reproducible; inspection only.", "Recreate the environment with the same Python version and project dependency files. Export needed package information and preserve local changes first.", manifest)
        }
        if fm.fileExists(atPath: url.appendingPathComponent("conda-meta/history").path) {
            return item("Conda environment", "Contains Conda environment state. It may be a shared base environment or contain manually installed libraries.", "Export and manage the environment with Conda. Shared environments are inspection-only here.", false)
        }
        if name == "site-packages" || name == "dist-packages" {
            return item("Shared Python libraries", "This may belong to a system interpreter, shared runtime or manually managed environment.", "Use the owning environment or package manager to inspect these packages. Individual shared libraries are not removed here.", false)
        }
        if name == ".build", marker("Package.swift") { return item("Swift build output", "Swift package build directory beside Package.swift. Contains generated build products and fetched dependencies.", "Build the package again. Dependencies may need downloading; preserve any edits inside checked-out dependencies.") }
        if name == "target", marker("Cargo.toml") { return item("Rust build output", "Build directory beside Cargo.toml. Review any manually stored artifacts before removing.", "Build the project again with Cargo.") }
        if [".next", ".nuxt", ".svelte-kit", ".parcel-cache"].contains(name), marker("package.json") { return item("Web build cache", "Recognized framework output beside package.json. Stop the development server before cleanup.", "Rebuild using the project's existing scripts and configuration.") }
        if name == "__pycache__" {
            let cached = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            let sources = cached?.isEmpty == false && cached?.allSatisfy { entry in
                guard entry.pathExtension == "pyc" else { return false }
                let module = entry.lastPathComponent.components(separatedBy: ".").first ?? ""
                return marker(module + ".py", in: parent)
            } == true
            return item("Python bytecode cache", sources ? "Each cached module has a matching Python source file beside the cache." : "Some cached modules have no matching source or the cache contains other files. Bytecode may be the only remaining copy; inspection only.", "Python normally regenerates bytecode when matching source modules run. Keep bytecode-only modules.", sources)
        }
        let path = url.standardizedFileURL.path
        let cacheSuffixes = ["/Library/Caches/pip", "/Library/Caches/uv", "/Library/Caches/Yarn", "/Library/Caches/pnpm", "/Library/Caches/Homebrew", "/.cache/pip", "/.cache/uv", "/.npm/_cacache", "/.gradle/caches", "/.cargo/registry"]
        if cacheSuffixes.contains(where: { path.hasSuffix($0) }) { return item("Package download cache", "Recognized package-manager cache. Cached downloads may be needed for offline work.", "The owning package manager can download packages again when network access is available. Project dependencies and lockfiles stay in place.") }
        if parent.path.hasSuffix("/Library/Developer/Xcode/DerivedData") { return item("Xcode derived data", "Generated Xcode build data, indexes and logs. Stop builds and close affected projects before cleanup.", "Xcode rebuilds indexes and products. Builds may take longer and dependencies may download again.") }
        if path.hasSuffix("/.m2/repository") { return item("Local Maven repository", "May contain locally published artifacts that are not available from a remote repository.", "Inspect with Maven and preserve locally published packages. This repository is inspection-only here.", false) }
        if path.hasSuffix("/Library/Developer/Xcode/Archives") { return item("Xcode archives", "Release archives and debug symbols can be required for distribution and crash symbolication.", "Inspect and manage archives in Xcode Organizer; they are not treated as disposable caches.", false) }
        return nil
    }
    private func validateScope(_ scope: URL) throws {
        let blocked = ["/", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/opt"]
        guard scope.isFileURL, !blocked.contains(where: { $0 == "/" ? scope.path == "/" : syncContains(URL(fileURLWithPath: $0), scope) }),
              let value = try? info(scope), isDirectory(value), !isLink(value), !cloud(scope) else { throw OpenFilesError.message("Choose a local project folder or your home folder, outside system and shared runtime directories.") }
    }
    private func shouldExplore(_ url: URL, scope: URL) -> Bool {
        let name = url.lastPathComponent
        if [".git", ".hg", ".svn", ".ssh", ".aws", ".Trash", "Applications", "System", "Photos Library.photoslibrary"].contains(name) { return false }
        if FileRules.packageExtensions.contains(url.pathExtension.lowercased()) { return false }
        if url != scope && name.hasPrefix(".") && ![".cache", ".npm", ".local", ".gradle", ".cargo", ".m2"].contains(name) { return false }
        // Home Library contains private application state. Visit only developer/cache branches.
        if url.deletingLastPathComponent().lastPathComponent == "Library", !["Caches", "Developer"].contains(name) { return false }
        return true
    }
    private func info(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return value
    }
    private func isDirectory(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFDIR }
    private func isLink(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFLNK }
    private func cloud(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true }
    private func measure(_ root: URL, scope: URL, limit: Int) throws -> DeveloperTree {
        guard scanRoots.contains(where: { syncContains($0, root) }), root.standardizedFileURL.path == root.canonical.path,
              !protected.contains(where: { syncContains(root, $0) || syncContains($0, root) }) else { throw OpenFilesError.message("Protected or redirected artifact") }
        let device = try info(root).st_dev
        var hash = SHA256(), bytes: Int64 = 0, count = 0
        // Rebuild evidence is part of the review too: changed manifests invalidate it.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for name in ["package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb", "requirements.txt", "pyproject.toml", "uv.lock", "poetry.lock", "Pipfile.lock", "environment.yml", "Package.swift", "Cargo.toml"] {
            let marker = root.deletingLastPathComponent().appendingPathComponent(name)
            if let stamp = try? FileStamp.read(marker) {
                hash.update(data: Data(name.utf8)); hash.update(data: try encoder.encode(stamp))
            }
        }
        var seen = Set<String>()
        func walk(_ url: URL) throws {
            try Task.checkCancellation()
            count += 1
            guard count <= limit, !protected.contains(where: { syncContains($0, url) }), !cloud(url) else { throw OpenFilesError.message("Incomplete artifact measurement") }
            let value = try info(url), stamp = try FileStamp.read(url)
            guard value.st_dev == device, value.st_mode & S_IFMT == S_IFREG || isDirectory(value) || isLink(value) else { throw OpenFilesError.message("Special files are excluded") }
            guard url.lastPathComponent != ".git" else { throw OpenFilesError.message("Contains a nested source repository") }
            let identity = "\(value.st_dev):\(value.st_ino)"
            if seen.insert(identity).inserted { bytes += Int64(value.st_blocks) * 512 }
            let relative = String(url.path.dropFirst(root.path.count))
            // JSON key ordering is not stable by default; encode stamps with sorted keys.
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let signature = try encoder.encode(stamp)
            hash.update(data: Data("\(relative.utf8.count):\(relative):\(value.st_mode):\(value.st_nlink):".utf8))
            hash.update(data: signature)
            if isLink(value) {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                hash.update(data: Data(destination.utf8)) // Record the link; never read its target.
            } else if isDirectory(value) {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) { try walk(child.standardizedFileURL) }
            }
            guard try FileStamp.read(url) == stamp else { throw OpenFilesError.message("Artifact changed during measurement") }
        }
        try walk(root)
        return DeveloperTree(fingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes, entries: count)
    }
}
