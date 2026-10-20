import Foundation
import OpenFilesCore

final class VaultChecks {
    func testEncryptedVaultRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["OPENFILES_TEST_VAULT"] == "1" else { print("SKIP encrypted vault (set OPENFILES_TEST_VAULT=1 to enable)"); return }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesVaultChecks-\(UUID())")
        let vault = EncryptedVault(directory: base.appendingPathComponent("Data"))
        let passphrase = UUID().uuidString + UUID().uuidString
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("sample.txt")
        try "Private test document".write(to: source, atomically: true, encoding: .utf8)
        do {
            let created = try await vault.create(password: passphrase)
            checkTrue(created.exists); checkTrue(created.mounted)
            let target = try await vault.importCopy(source)
            checkEqual(try Data(contentsOf: target), try Data(contentsOf: source))
            checkTrue(FileManager.default.fileExists(atPath: source.path))
            let locked = try await vault.lock(); checkFalse(locked.mounted)
            do { _ = try await vault.unlock(password: "incorrect-password"); failCheck("Wrong password must not unlock") } catch {}
            let unlocked = try await vault.unlock(password: passphrase); checkTrue(unlocked.mounted)
            checkEqual(try String(contentsOf: target), "Private test document")
            _ = try await vault.lock()
            try FileManager.default.removeItem(at: base)
            print("PASS Encrypted vault create/import/lock/wrong-password/unlock")
        } catch {
            _ = try? await vault.lock(); try? FileManager.default.removeItem(at: base); throw error
        }
    }
}
