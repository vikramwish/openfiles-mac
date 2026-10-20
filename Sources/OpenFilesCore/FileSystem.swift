import Foundation
import CryptoKit

// Content hashes detect torn snapshots. Project folders are opaque full copies, not Git diffs.
public enum FileIntegrity {
    public static func digest(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else { throw OpenFilesError.message("Symbolic links are excluded from snapshots and moves.") }
        var hash = SHA256()
        if values.isDirectory == true {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                // Length-prefix names to make directory hashes unambiguous.
                let name = child.lastPathComponent
                hash.update(data: Data("\(name.utf8.count):\(name):\(try digest(child));".utf8))
            }
        } else {
            guard values.isRegularFile == true else { throw OpenFilesError.message("Only regular files and project folders are supported.") }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension URL {
    var canonical: URL { resolvingSymlinksInPath().standardizedFileURL }
}
