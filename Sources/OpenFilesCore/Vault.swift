import Foundation

/// Uses a real AES-256 encrypted APFS sparse bundle, rather than hiding a normal folder.
public actor EncryptedVault {
    public let directory: URL
    public var image: URL { directory.appendingPathComponent("Private.sparsebundle") }
    public var mount: URL { directory.appendingPathComponent("vault-mount") }
    private let fm = FileManager.default
    public init(directory: URL) { self.directory = directory.canonical }
    public func status() -> VaultState {
        let volume = try? mount.resourceValues(forKeys: [.volumeURLKey]).volume
        let parentVolume = try? directory.resourceValues(forKeys: [.volumeURLKey]).volume
        return VaultState(exists: fm.fileExists(atPath: image.path), mounted: volume != nil && volume != parentVolume)
    }
    private func validate(_ password: String, creating: Bool = false) throws -> Data {
        guard password.count >= (creating ? 12 : 1), password.utf8.count <= 1024, !password.contains("\0") else { throw OpenFilesError.message(creating ? "Use a password of at least 12 characters." : "Enter your vault password.") }
        return Data((password + "\0").utf8)
    }
    private func run(_ arguments: [String], input: Data? = nil) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); process.arguments = arguments
        let output = Pipe(), stdin = Pipe()
        // Combined output avoids pipe deadlocks. Passwords go only through stdin, never arguments.
        process.standardOutput = output; process.standardError = output; process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try? stdin.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OpenFilesError.message(String(data: result, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Vault operation failed.")
        }
    }
    public func create(password: String) throws -> VaultState {
        let data = try validate(password, creating: true)
        guard !status().exists else { throw OpenFilesError.message("A vault already exists.") }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try run(["create", "-size", "10g", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-volname", "OpenFiles Private", "-encryption", "AES-256", "-stdinpass", image.path], input: data)
        return try unlock(password: password)
    }
    public func unlock(password: String) throws -> VaultState {
        let input = try validate(password)
        guard status().exists else { throw OpenFilesError.message("Create a vault first.") }
        if status().mounted { return status() }
        try fm.createDirectory(at: mount, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try run(["attach", image.path, "-stdinpass", "-nobrowse", "-mountpoint", mount.path], input: input)
        return status()
    }
    public func lock() throws -> VaultState {
        if status().mounted { try run(["detach", mount.path]) }
        return status()
    }
    public func mountedURL() throws -> URL {
        guard status().mounted else { throw OpenFilesError.message("Unlock the vault first.") }
        return mount
    }
    public func importCopy(_ source: URL) throws -> URL {
        let targetFolder = try mountedURL()
        guard try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              !FileRules.contains(directory, source.canonical) else { throw OpenFilesError.message("Choose a regular file outside OpenFiles app data.") }
        let digest = try FileIntegrity.digest(source)
        let target = targetFolder.appendingPathComponent(source.lastPathComponent)
        try fm.copyItem(at: source, to: target)
        guard try FileIntegrity.digest(target) == digest else { throw OpenFilesError.message("Copy verification failed. The original is unchanged.") }
        // Deliberately retain the original: secure deletion and external app references need a separate workflow.
        return target
    }
}
