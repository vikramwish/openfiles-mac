// A dependency-free check runner: Apple's Command Line Tools do not bundle XCTest.
// All checks run sequentially on temporary fixtures; failures produce a nonzero exit.
import Foundation

private final class CheckLog: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var failures: Int { lock.lock(); defer { lock.unlock() }; return count }
    func fail(_ message: String, file: StaticString, line: UInt) {
        lock.lock(); defer { lock.unlock() }; count += 1
        print("FAIL \(file):\(line): \(message)")
    }
}
private let log = CheckLog()
func failCheck(_ message: String, file: StaticString = #filePath, line: UInt = #line) { log.fail(message, file: file, line: line) }
func checkTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { failCheck("Expected true", file: file, line: line) } } catch { failCheck(error.localizedDescription, file: file, line: line) }
}
func checkFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() { failCheck("Expected false", file: file, line: line) } } catch { failCheck(error.localizedDescription, file: file, line: line) }
}
func checkNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() != nil { failCheck("Expected nil", file: file, line: line) } } catch { failCheck(error.localizedDescription, file: file, line: line) }
}
func checkEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { if try lhs() != rhs() { failCheck("Values are not equal", file: file, line: line) } } catch { failCheck(error.localizedDescription, file: file, line: line) }
}
func checkEqual(_ lhs: Double, _ rhs: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    if abs(lhs - rhs) > accuracy { failCheck("Values differ beyond tolerance", file: file, line: line) }
}
@main
struct Runner {
    static func main() async {
        let checks: [(String, (LibraryChecks) async throws -> Void)] = [
            ("Local search, sensitive exclusion, persistence", { try await $0.testSearchExcludesSensitiveEmbeddingsAndPersistence() }),
            ("Binary project snapshot and non-destructive restore", { try await $0.testBinaryAndProjectSnapshotsRestoreWithoutOverwriting() }),
            ("Tampered snapshot rejection", { try await $0.testTamperedSnapshotIsRejected() }),
            ("Organization collisions and sensitive exclusion", { try await $0.testOrganizationDoesNotOverwriteOrMoveSensitiveFiles() }),
            ("Stale preview rejection and verified move", { try await $0.testOrganizationVerifiesStalePreviewAndSuccessfulMove() }),
            ("Folder boundaries and symbolic links", { try await $0.testBoundariesAndSymlinks() }),
            ("Sensitive project exclusion", { try await $0.testSensitiveProjectContentCannotEnterHistory() }),
            ("Destination symlink refusal", { try await $0.testOrganizationCannotFollowDestinationSymlink() }),
            ("File categories and similarity", { $0.testPureRules() })
        ]
        for (name, check) in checks {
            let suite = LibraryChecks(), previous = log.failures
            do { try suite.setUpWithError(); try await check(suite); try suite.tearDownWithError() }
            catch { failCheck("\(name): \(error.localizedDescription)"); try? suite.tearDownWithError() }
            print("\(log.failures == previous ? "PASS" : "FAIL") \(name)")
        }
        do { try await VaultChecks().testEncryptedVaultRoundTrip() } catch { failCheck("Encrypted vault: \(error.localizedDescription)") }
        print("\(checks.count) core scenarios; \(log.failures) failures")
        exit(log.failures == 0 ? 0 : 1)
    }
}
