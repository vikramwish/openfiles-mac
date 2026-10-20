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
        if CommandLine.arguments.contains("--screenshots") {
            for (name, scenario) in ScreenshotChecks.scenarios {
                let previous = log.failures
                do { try await scenario() } catch { failCheck(error.localizedDescription) }
                print("\(log.failures == previous ? "PASS" : "FAIL") \(name)")
            }
            print("\(ScreenshotChecks.scenarios.count) screenshot scenarios; \(log.failures) failures")
            exit(log.failures == 0 ? 0 : 1)
        }
        if CommandLine.arguments.contains("--collections") {
            for (name, scenario) in CollectionChecks.scenarios {
                let previous = log.failures
                do { try await scenario() } catch { failCheck(error.localizedDescription) }
                print("\(log.failures == previous ? "PASS" : "FAIL") \(name)")
            }
            print("\(CollectionChecks.scenarios.count) collection scenarios; \(log.failures) failures")
            exit(log.failures == 0 ? 0 : 1)
        }
        if CommandLine.arguments.contains("--photo-similarity") {
            for (name, scenario) in PhotoSimilarityChecks.scenarios {
                let previous = log.failures
                do { try await scenario() } catch { failCheck(error.localizedDescription) }
                print("\(log.failures == previous ? "PASS" : "FAIL") \(name)")
            }
            print("\(PhotoSimilarityChecks.scenarios.count) photo similarity scenarios; \(log.failures) failures")
            exit(log.failures == 0 ? 0 : 1)
        }
        if CommandLine.arguments.contains("--organization") {
            for (name, check) in OrganizationChecks.scenarios + DynamicMacChecks.scenarios {
                let previous = log.failures
                do { try await check() } catch { failCheck("\(name): \(error.localizedDescription)") }
                print("\(log.failures == previous ? "PASS" : "FAIL") \(name)")
            }
            print("\(OrganizationChecks.scenarios.count + DynamicMacChecks.scenarios.count) organization scenarios; \(log.failures) failures")
            exit(log.failures == 0 ? 0 : 1)
        }
        if CommandLine.arguments.contains("--photo-tools") {
            for (name, scenario) in PhotoToolChecks.scenarios {
                let previous = log.failures
                do { try await scenario() } catch { failCheck(error.localizedDescription) }
                print("\(log.failures == previous ? "PASS" : "FAIL") \(name)")
            }
            print("\(PhotoToolChecks.scenarios.count) photo tool scenarios; \(log.failures) failures")
            exit(log.failures == 0 ? 0 : 1)
        }
        if CommandLine.arguments.contains("--index") {
            let scenarios = IndexChecks.scenarios + PipelineOptimizationChecks.scenarios
            for (name, check) in scenarios {
                let previous = log.failures
                do { try await check() } catch { failCheck("\(name): \(error.localizedDescription)") }
                print("\(log.failures == previous ? "PASS" : "FAIL") \(name)")
            }
            print("\(scenarios.count) indexing scenarios; \(log.failures) failures")
            exit(log.failures == 0 ? 0 : 1)
        }
        if CommandLine.arguments.contains("--photoslibrary") {
            do { try await NavigationChecks.photosLibraries() } catch { failCheck(error.localizedDescription) }
            print("Photos library checks; \(log.failures) failures")
            exit(log.failures == 0 ? 0 : 1)
        }
        if CommandLine.arguments.contains("--cleanup") {
            for (name, check) in CleanupChecks.scenarios + DeveloperCleanupChecks.scenarios + DynamicMacChecks.scenarios {
                let previous = log.failures
                do { try await check() } catch { failCheck("\(name): \(error.localizedDescription)") }
                print("\(log.failures == previous ? "PASS" : "FAIL") \(name)")
            }
            print("\(CleanupChecks.scenarios.count + DeveloperCleanupChecks.scenarios.count + DynamicMacChecks.scenarios.count) cleanup scenarios; \(log.failures) failures")
            exit(log.failures == 0 ? 0 : 1)
        }
        if CommandLine.arguments.contains("--versions") {
            for (name, check) in VersionChecks.scenarios {
                let previous = log.failures
                do { try await check() } catch { failCheck("\(name): \(error.localizedDescription)") }
                print("\(log.failures == previous ? "PASS" : "FAIL") \(name)")
            }
            print("\(VersionChecks.scenarios.count) version scenarios; \(log.failures) failures")
            exit(log.failures == 0 ? 0 : 1)
        }
        let checks: [(String, (LibraryChecks) async throws -> Void)] = [
            ("Natural-language search relevance and dependency exclusion", { try await $0.testGroundedNaturalLanguageSearch() }),
            ("Local search, sensitive exclusion, persistence", { try await $0.testSearchExcludesSensitiveEmbeddingsAndPersistence() }),
            ("Binary project snapshot and non-destructive restore", { try await $0.testBinaryAndProjectSnapshotsRestoreWithoutOverwriting() }),
            ("Tampered snapshot rejection", { try await $0.testTamperedSnapshotIsRejected() }),
            ("Organization collisions and sensitive exclusion", { try await $0.testOrganizationDoesNotOverwriteOrMoveSensitiveFiles() }),
            ("Stale preview rejection and verified move", { try await $0.testOrganizationVerifiesStalePreviewAndSuccessfulMove() }),
            ("Folder boundaries and symbolic links", { try await $0.testBoundariesAndSymlinks() }),
            ("Sensitive project exclusion", { try await $0.testSensitiveProjectContentCannotEnterHistory() }),
            ("Destination symlink refusal", { try await $0.testOrganizationCannotFollowDestinationSymlink() }),
            ("Browser without connected roots or index cap", { try await $0.testBrowserWorksWithoutConnectedRootsAndHasNoIndexCap() }),
            ("Browser folder creation and symlink navigation", { try await $0.testBrowserFolderCreationAndSymlinkNavigation() }),
            ("Default discovery cannot authorize organization", { try await $0.testDefaultSearchDiscoveryDoesNotAuthorizeOrganization() }),
            ("Per-file version history and saved changes", { try await $0.testFileHistoryAndSavedChangeStatus() }),
            ("File categories and similarity", { $0.testPureRules() })
        ]
        for (name, check) in checks {
            let suite = LibraryChecks(), previous = log.failures
            do { try suite.setUpWithError(); try await check(suite); try suite.tearDownWithError() }
            catch { failCheck("\(name): \(error.localizedDescription)"); try? suite.tearDownWithError() }
            print("\(log.failures == previous ? "PASS" : "FAIL") \(name)")
        }
        let scenarioGroups = [IndexChecks.scenarios, PipelineOptimizationChecks.scenarios, NavigationChecks.scenarios, PhotoToolChecks.scenarios, ScreenshotChecks.scenarios, PhotoSimilarityChecks.scenarios, ImageContentChecks.scenarios, OrganizationChecks.scenarios, EmbeddingGemmaChecks.scenarios, DocumentPackChecks.scenarios, CollectionChecks.scenarios, AutomaticHistoryChecks.scenarios, CleanupChecks.scenarios, RenameChecks.scenarios, DeveloperCleanupChecks.scenarios, DynamicMacChecks.scenarios, CloudPlacementChecks.scenarios]
        for (name, check) in scenarioGroups.flatMap({ $0 }) {
            let previous = log.failures
            do { try await check() } catch { failCheck("\(name): \(error.localizedDescription)") }
            print("\(log.failures == previous ? "PASS" : "FAIL") \(name)")
        }
        for (name, check) in VersionChecks.scenarios {
            let previous = log.failures
            do { try await check() } catch { failCheck("\(name): \(error.localizedDescription)") }
            print("\(log.failures == previous ? "PASS" : "FAIL") \(name)")
        }
        do { try await VaultChecks().testEncryptedVaultRoundTrip() } catch { failCheck("Encrypted vault: \(error.localizedDescription)") }
do { try await EmbeddingGemmaChecks.realModelIfRequested() } catch { failCheck("EmbeddingGemma 2: \(error.localizedDescription)") }
        let totalScenarios = checks.count + scenarioGroups.reduce(0) { $0 + $1.count } + VersionChecks.scenarios.count
        print("\(totalScenarios) core scenarios; \(log.failures) failures")
        exit(log.failures == 0 ? 0 : 1)
    }
}
