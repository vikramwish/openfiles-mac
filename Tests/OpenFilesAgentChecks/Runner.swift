import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenFilesAgent
import OpenFilesCore

// These scenarios use no network, no API keys and no personal folders.
struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(message) }
}

func expectError(_ operation: () async throws -> Void,
                 matching predicate: (Error) -> Bool) async throws {
    do { try await operation() }
    catch {
        guard predicate(error) else { throw CheckFailure("Unexpected error: \(error)") }
        return
    }
    throw CheckFailure("Expected the operation to fail")
}

struct Reply: Sendable {
    let status: Int
    let body: Data
    init(_ body: String, status: Int = 200) {
        self.status = status; self.body = Data(body.utf8)
    }
}

actor MockTransport: AgentHTTPTransport {
    private var replies: [Reply]
    private var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let reply = replies.isEmpty ? Reply("{}", status: 500) : replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (reply.body, response)
    }
    func recorded() -> [URLRequest] { requests }
}

@main
struct Runner {
    static func main() async {
        let scenarios: [(String, () async throws -> Void)] = [
            ("Agent plan decoding accepts renames, moves and navigation", AgentChecks.planDecodingAcceptsActions),
            ("Agent plan decoding drops unknown kinds, invalid names and caps the list", AgentChecks.planDecodingRefusesUnknownAndCaps),
            ("Agent prompts bound context and excerpts", AgentChecks.promptBoundaries),
            ("Agent client builds an OpenAI-compatible request and parses fenced JSON", AgentChecks.clientRequestAndFencedJSON),
            ("Agent client reports provider errors and lists models", AgentChecks.clientErrorsAndModels),
            ("Agent move preview refuses unsafe sources and destinations", AgentChecks.movePreviewRefusesUnsafeSources),
            ("Agent move apply re-verifies files and never replaces originals", AgentChecks.moveApplyReverifies)
        ]
        var failures = 0
        for (name, scenario) in scenarios {
            do { try await scenario(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(scenarios.count) agent scenarios; \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
