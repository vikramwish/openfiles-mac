import Foundation

/// The callback is deliberately parsed independently of Network.framework so
/// request validation can be exercised without a browser, credentials, or macOS.
public enum CloudOAuthCallback: Equatable, Sendable {
    case code(String)
    case denied
    case invalidRequest

    public static func parse(_ data: Data, expectedHost: String, expectedState: String) -> CloudOAuthCallback {
        guard data.count <= 16_384, !expectedHost.isEmpty, !expectedState.isEmpty,
              let boundary = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else {
            return .invalidRequest
        }
        // Only the header block is inspected. A request body cannot supply Host
        // or replace another header, including in malformed requests.
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[0] == "GET",
              request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0",
              request[1].utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }),
              request[1].hasPrefix("/"), !request[1].hasPrefix("//"),
              let components = URLComponents(string: "http://localhost" + String(request[1])),
              components.percentEncodedPath == "/callback", components.fragment == nil else {
            return .invalidRequest
        }
        let fieldCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var hosts: [String] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalidRequest }
            let name = line[..<colon]
            let value = line[line.index(after: colon)...]
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ fieldCharacters.contains($0) }),
                  value.unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) }) else {
                return .invalidRequest
            }
            if name.lowercased() == "host" {
                hosts.append(value.trimmingCharacters(in: CharacterSet(charactersIn: " \t")).lowercased())
            }
        }
        guard hosts.count == 1, hosts[0] == expectedHost.lowercased() else { return .invalidRequest }
        let items = components.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              let state = items.first(where: { $0.name == "state" })?.value,
              matches(state, expectedState) else { return .invalidRequest }
        let code = items.first(where: { $0.name == "code" })
        let error = items.first(where: { $0.name == "error" })
        if let value = code?.value, !value.isEmpty, error == nil { return .code(value) }
        if let value = error?.value, !value.isEmpty, code == nil { return .denied }
        return .invalidRequest
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
