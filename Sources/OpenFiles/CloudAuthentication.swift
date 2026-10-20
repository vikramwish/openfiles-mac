import AppKit
import CryptoKit
import Foundation
import Network
import OpenFilesCloud
import Security

/// Account credentials never enter library.json or UserDefaults. Each provider has
/// separate Keychain entries for its registration and its renewable OAuth token.
actor KeychainCloudStore: CloudCredentialStore {
    private let service = "com.openfiles.desktop.cloud"

    func load(for provider: CloudProvider) async throws -> CloudToken? {
        try read(CloudToken.self, account: "token.\(provider.rawValue)")
    }

    func save(_ token: CloudToken, for provider: CloudProvider) async throws {
        try Task.checkCancellation()
        try write(token, account: "token.\(provider.rawValue)")
    }

    func remove(for provider: CloudProvider) async throws {
        try delete(account: "token.\(provider.rawValue)")
    }

    func loadConfiguration(for provider: CloudProvider) async throws -> CloudConfiguration? {
        try read(CloudConfiguration.self, account: "configuration.\(provider.rawValue)")
    }

    func saveConfiguration(_ configuration: CloudConfiguration) async throws {
        try Task.checkCancellation()
        try write(configuration, account: "configuration.\(configuration.provider.rawValue)")
    }

    func removeConfiguration(for provider: CloudProvider) async throws {
        try delete(account: "configuration.\(provider.rawValue)")
    }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    private func read<Value: Decodable>(_ type: Value.Type, account: String) throws -> Value? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CloudAuthenticationError.keychain(status)
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw CloudAuthenticationError.invalidSavedCredential }
    }

    private func write<Value: Encodable>(_ value: Value, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let request = query(account: account)
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = request
            attributes.forEach { insertion[$0.key] = $0.value }
            status = SecItemAdd(insertion as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CloudAuthenticationError.keychain(status) }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudAuthenticationError.keychain(status)
        }
    }
}

enum CloudAuthenticationError: LocalizedError {
    case keychain(OSStatus)
    case invalidSavedCredential
    case randomGeneration
    case alreadySigningIn
    case listenerUnavailable
    case browserUnavailable
    case timedOut
    case authorizationDeclined

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "OpenFiles could not access its cloud credentials in Keychain (\(status)). Unlock your login keychain and try again."
        case .invalidSavedCredential:
            return "The saved cloud credential could not be read. Disconnect this provider and configure it again."
        case .randomGeneration:
            return "A secure sign-in request could not be created. Try again."
        case .alreadySigningIn:
            return "A cloud sign-in is already in progress. Finish or cancel it first."
        case .listenerUnavailable:
            return "OpenFiles could not start its local sign-in callback. Check local network permissions and try again."
        case .browserUnavailable:
            return "The sign-in page could not be opened in your default browser."
        case .timedOut:
            return "Sign-in timed out. Choose Connect to try again."
        case .authorizationDeclined:
            return "The provider did not authorize this connection. Check the app registration and consent settings, then try again."
        }
    }
}

/// Native public-client sign-in uses the user's browser, PKCE, and a short-lived
/// loopback listener. Microsoft app registrations use http://localhost/callback;
/// the provider ignores the ephemeral port for native localhost redirects.
@MainActor
final class CloudAuthenticator {
    private var receiver: OAuthLoopbackReceiver?
    private var signInTask: Task<Void, Error>?

    func signIn(client: CloudClient, provider: CloudProvider) async throws {
        guard signInTask == nil else { throw CloudAuthenticationError.alreadySigningIn }
        let verifier = try Self.randomURLSafeString()
        let state = try Self.randomURLSafeString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let receiver = OAuthLoopbackReceiver(provider: provider, expectedState: state)
        self.receiver = receiver
        let task = Task {
            let redirectURI = try await receiver.start()
            let authorizationURL = try await client.authorizationURL(redirectURI: redirectURI, state: state, challenge: challenge)
            try Task.checkCancellation()
            guard NSWorkspace.shared.open(authorizationURL) else { throw CloudAuthenticationError.browserUnavailable }
            let code = try await receiver.authorizationCode()
            try Task.checkCancellation()
            try await client.completeSignIn(code: code, redirectURI: redirectURI, verifier: verifier)
            try Task.checkCancellation()
        }
        signInTask = task
        defer {
            receiver.cancel()
            self.receiver = nil
            signInTask = nil
        }
        try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
            Task { @MainActor in receiver.cancel() }
        })
    }

    func cancel() {
        signInTask?.cancel()
        receiver?.cancel()
    }

    private static func randomURLSafeString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw CloudAuthenticationError.randomGeneration }
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class OAuthLoopbackReceiver {
    private let provider: CloudProvider
    private let expectedState: String
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var timeout: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<String, Error>?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var outcome: Result<String, Error>?
    private var expectedHost: String?

    init(provider: CloudProvider, expectedState: String) {
        self.provider = provider
        self.expectedState = expectedState
    }

    func start() async throws -> String {
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters, on: .any) }
        catch { throw CloudAuthenticationError.listenerUnavailable }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [self] in self.listenerChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { @MainActor [self] in
                guard self.outcome == nil else { connection.cancel(); return }
                // Bound resource usage even if another local process sends junk.
                guard self.connections.count < 8 else { connection.cancel(); return }
                let identifier = UUID()
                self.connections[identifier] = connection
                connection.start(queue: .main)
                self.receive(connection, identifier: identifier, buffer: Data())
            }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) }
            catch { return }
            self?.finish(.failure(CloudAuthenticationError.timedOut))
        }
        return try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            listener.start(queue: .main)
        }
    }

    func authorizationCode() async throws -> String {
        try Task.checkCancellation()
        if let outcome { return try outcome.get() }
        return try await withCheckedThrowingContinuation { codeContinuation = $0 }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func listenerChanged(_ state: NWListener.State) {
        guard outcome == nil else { return }
        switch state {
        case .ready:
            guard let port = listener?.port else { finish(.failure(CloudAuthenticationError.listenerUnavailable)); return }
            let host = provider == .googleDrive ? "127.0.0.1" : "localhost"
            expectedHost = "\(host):\(port.rawValue)"
            let uri = "http://\(host):\(port.rawValue)/callback"
            let continuation = readyContinuation
            readyContinuation = nil
            continuation?.resume(returning: uri)
        case .failed:
            finish(.failure(CloudAuthenticationError.listenerUnavailable))
        case .cancelled:
            finish(.failure(CancellationError()))
        default: break
        }
    }

    private func receive(_ connection: NWConnection, identifier: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            Task { @MainActor [self] in
                guard self.connections[identifier] != nil else { return }
                var received = buffer
                if let data { received.append(data) }
                if received.count > 16_384 {
                    self.respond(connection, identifier: identifier, status: "431 Request Header Fields Too Large", message: "Invalid sign-in request.")
                    return
                }
                if received.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.handle(received, connection: connection, identifier: identifier)
                } else if complete || error != nil {
                    self.connections.removeValue(forKey: identifier)
                    connection.cancel()
                } else {
                    self.receive(connection, identifier: identifier, buffer: received)
                }
            }
        }
    }

    private func handle(_ data: Data, connection: NWConnection, identifier: UUID) {
        let result: Result<String, Error>
        switch CloudOAuthCallback.parse(data, expectedHost: expectedHost ?? "", expectedState: expectedState) {
        case .code(let code):
            result = .success(code)
        case .denied:
            result = .failure(CloudAuthenticationError.authorizationDeclined)
        case .invalidRequest:
            // Unrelated and forged callbacks do not terminate the pending flow.
            respond(connection, identifier: identifier, status: "400 Bad Request", message: "This sign-in request could not be verified. Continue in the original sign-in tab."); return
        }
        respond(connection, identifier: identifier, status: "200 OK", message: "Return to OpenFiles to finish connecting. You can close this tab.", result: result)
    }

    private func respond(_ connection: NWConnection, identifier: UUID, status: String, message: String, result: Result<String, Error>? = nil) {
        let body = Data(message.utf8)
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nPragma: no-cache\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            guard let self else { connection.cancel(); return }
            Task { @MainActor [self] in
                connection.cancel()
                self.connections.removeValue(forKey: identifier)
                if let result { self.finish(result) }
            }
        })
    }

    private func finish(_ result: Result<String, Error>) {
        guard outcome == nil else { return }
        outcome = result
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        let ready = readyContinuation, code = codeContinuation
        readyContinuation = nil; codeContinuation = nil
        if let ready {
            switch result {
            case .success: ready.resume(throwing: CloudAuthenticationError.listenerUnavailable)
            case .failure(let error): ready.resume(throwing: error)
            }
        }
        code?.resume(with: result)
    }

}
