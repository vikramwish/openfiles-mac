import Foundation
import OpenFilesCore

private struct DeveloperTestTrash: CleanupTrash {
    let directory: URL
    func moveToTrash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}
struct DeveloperCleanupChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Developer cleanup finds dependencies and caches independently of the search index", discovery),
        ("Developer cleanup retains source, lockfiles and external symlink targets", reversibleMove),
        ("Developer cleanup rejects changed trees, protected descendants and redirected folders", safeguards),
        ("Developer cleanup keeps VM disks, shared runtimes and unreproducible environments inspection-only", valuableState),
        ("Developer cleanup marks incomplete measurements and bounded discovery", limits),
        ("Python bytecode cleanup requires a matching source for every cached module", bytecode)
    ]
    private static func fixture() throws -> (URL, URL, DeveloperCleanupService) {
        let base = URL(fileURLWithPath: "/private/tmp/OpenFilesDev-\(UUID())", isDirectory: true).canonicalForTest
        let scope = base.appendingPathComponent("Workspace")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        let service = DeveloperCleanupService(directory: base.appendingPathComponent("Data"), trash: DeveloperTestTrash(directory: base.appendingPathComponent("TestTrash")))
        return (base, scope, service)
    }
    @discardableResult private static func write(_ name: String, _ text: String = "fixture", at parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private static func rejects(_ operation: () async throws -> Void) async {
        do { try await operation(); failCheck("Developer cleanup should reject this action") } catch {}
    }
    static func discovery() async throws {
        let (base, scope, service) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        try write("package.json", "{}", at: scope); try write("package-lock.json", "{}", at: scope)
        try write("node_modules/pkg/index.js", "module.exports = 1", at: scope)
        try write("node_modules/pkg/node_modules/nested/index.js", at: scope)
        try write("requirements.txt", "requests==2.0", at: scope)
        try write(".venv/pyvenv.cfg", "home = /usr/bin", at: scope)
        try write(".venv/lib/python3.12/site-packages/sample.py", at: scope)
        try write("Package.swift", at: scope); try write(".build/debug/App", at: scope)
        try write("Cargo.toml", at: scope); try write("target/debug/app", at: scope)
        try write(".next/cache/chunk", at: scope)
        try write("Home/Library/Caches/pip/wheels/file.whl", at: scope)
        try write("Home/.npm/_cacache/content/package", at: scope)
        let plan = try await service.preview(scope: scope)
        checkEqual(plan.items.count, 7)
        checkTrue(plan.items.allSatisfy(\.canTrash)); checkTrue(plan.items.allSatisfy(\.complete))
        checkTrue(plan.items.allSatisfy { $0.bytes > 0 && $0.entries > 1 })
        checkEqual(plan.items.filter { $0.url.lastPathComponent == "node_modules" }.count, 1)
        checkTrue(plan.items.contains { $0.category == "Python virtual environment" })
        checkTrue(FileManager.default.fileExists(atPath: scope.appendingPathComponent("node_modules/pkg/index.js").path))
    }
    static func reversibleMove() async throws {
        let (base, scope, service) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let manifest = try write("package.json", "{}", at: scope), lock = try write("pnpm-lock.yaml", "lockfileVersion: 9", at: scope)
        let source = try write("src/main.js", "important original source", at: scope)
        let external = try write("external/source.js", "linked workspace source", at: base)
        let dependency = try write("node_modules/lib/index.js", "dependency", at: scope)
        let link = scope.appendingPathComponent("node_modules/workspace")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external.deletingLastPathComponent())
        let original = try Data(contentsOf: source), before = try FileStamp.read(source)
        let plan = try await service.preview(scope: scope)
        guard let item = plan.items.first else { failCheck("Missing dependency candidate"); return }
        checkEqual(item.url.lastPathComponent, "node_modules"); checkTrue(item.canTrash)
        await rejects { _ = try await service.apply(reviewID: plan.id, selected: [item.id], workloadsStopped: false) }
        let result = try await service.apply(reviewID: plan.id, selected: [item.id], workloadsStopped: true)
        checkTrue(result.errors.isEmpty); checkEqual(result.receipts.count, 1)
        checkFalse(FileManager.default.fileExists(atPath: dependency.path))
        checkEqual(try Data(contentsOf: source), original); checkEqual(try FileStamp.read(source), before)
        checkTrue(FileManager.default.fileExists(atPath: manifest.path)); checkTrue(FileManager.default.fileExists(atPath: lock.path))
        checkEqual(try String(contentsOf: external), "linked workspace source")
        checkEqual(try String(contentsOf: result.receipts[0].trashed.appendingPathComponent("lib/index.js")), "dependency")
        checkEqual(try FileManager.default.destinationOfSymbolicLink(atPath: result.receipts[0].trashed.appendingPathComponent("workspace").path), external.deletingLastPathComponent().path)
        await rejects { _ = try await service.apply(reviewID: plan.id, selected: [item.id], workloadsStopped: true) }
    }
    static func safeguards() async throws {
        let (base, scope, service) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        try write("package.json", "{}", at: scope); try write("package-lock.json", "{}", at: scope)
        let dependency = try write("node_modules/pkg/code.js", at: scope)
        var plan = try await service.preview(scope: scope)
        guard let item = plan.items.first else { failCheck("Missing candidate"); return }
        try write("node_modules/pkg/local-edit.js", "valuable local change", at: scope)
        await rejects { _ = try await service.apply(reviewID: plan.id, selected: [item.id], workloadsStopped: true) }
        checkTrue(FileManager.default.fileExists(atPath: dependency.path))
        plan = try await service.preview(scope: scope)
        guard let manifestItem = plan.items.first else { failCheck("Missing manifest candidate"); return }
        try write("package-lock.json", "changed lockfile", at: scope)
        await rejects { _ = try await service.apply(reviewID: plan.id, selected: [manifestItem.id], workloadsStopped: true) }
        plan = try await service.preview(scope: scope, excluding: [dependency])
        checkTrue(plan.items.allSatisfy { !$0.canTrash })
        plan = try await service.preview(scope: scope)
        guard let protectedItem = plan.items.first else { failCheck("Missing candidate"); return }
        await rejects { _ = try await service.apply(reviewID: plan.id, selected: [protectedItem.id], workloadsStopped: true, excluding: [dependency]) }
        plan = try await service.preview(scope: scope)
        guard let redirected = plan.items.first else { failCheck("Missing candidate"); return }
        let modules = scope.appendingPathComponent("node_modules"), saved = base.appendingPathComponent("saved-modules")
        try FileManager.default.moveItem(at: modules, to: saved)
        try FileManager.default.createSymbolicLink(at: modules, withDestinationURL: saved)
        await rejects { _ = try await service.apply(reviewID: plan.id, selected: [redirected.id], workloadsStopped: true) }
        checkTrue(FileManager.default.fileExists(atPath: saved.appendingPathComponent("pkg/code.js").path))
        let linkedPlan = try await service.preview(scope: scope)
        checkTrue(linkedPlan.items.isEmpty)
    }
    static func valuableState() async throws {
        let (base, scope, service) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        try write("Unrecorded/.venv/pyvenv.cfg", "home = /usr/bin", at: scope)
        try write("Unrecorded/.venv/lib/module.py", at: scope)
        try write("Unlocked/package.json", "{}", at: scope)
        try write("Unlocked/node_modules/pkg/index.js", at: scope)
        try write("server.qcow2", "unique virtual disk", at: scope)
        try write("Guest.utm/Data/disk.img", "unique VM contents", at: scope)
        try write("Python/lib/site-packages/lib.py", at: scope)
        try write(".docker/volumes/database", "unique database", at: scope)
        let plan = try await service.preview(scope: scope)
        checkEqual(plan.items.count, 6); checkTrue(plan.items.allSatisfy { !$0.canTrash })
        checkTrue(plan.items.contains { $0.category == "Virtual machine / container disk" })
        guard let vm = plan.items.first(where: { $0.url.lastPathComponent == "Guest.utm" }) else { failCheck("Missing VM"); return }
        await rejects { _ = try await service.apply(reviewID: plan.id, selected: [vm.id], workloadsStopped: true) }
        checkEqual(try String(contentsOf: scope.appendingPathComponent("Guest.utm/Data/disk.img")), "unique VM contents")
    }
    static func bytecode() async throws {
        let (base, scope, service) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        try write("code/module.py", "print(1)", at: scope)
        try write("code/__pycache__/module.cpython-312.pyc", "cached bytecode", at: scope)
        var plan = try await service.preview(scope: scope)
        checkEqual(plan.items.count, 1); checkTrue(plan.items.first?.canTrash == true)
        try write("code/__pycache__/orphan.cpython-312.pyc", "only remaining copy", at: scope)
        plan = try await service.preview(scope: scope)
        checkEqual(plan.items.count, 1); checkTrue(plan.items.first?.canTrash == false)
    }
    static func limits() async throws {
        let (base, scope, service) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        try write("package.json", "{}", at: scope); try write("package-lock.json", "{}", at: scope)
        try write("node_modules/pkg/source.js", at: scope)
        let partial = try await service.preview(scope: scope, treeLimit: 1)
        checkTrue(partial.limited); checkTrue(partial.items.allSatisfy { !$0.canTrash && !$0.complete })
        let bounded = try await service.preview(scope: scope, discoveryLimit: 1)
        checkTrue(bounded.limited)
        try write("node_modules/pkg/.git/config", "local source checkout", at: scope)
        let source = try await service.preview(scope: scope)
        checkTrue(source.items.allSatisfy { !$0.canTrash })
        await rejects { _ = try await service.preview(scope: URL(fileURLWithPath: "/usr")) }
    }
}
private extension URL { var canonicalForTest: URL { resolvingSymlinksInPath().standardizedFileURL } }
