import Foundation

extension FileLibrary {
    /// Reconcile only the paths supplied by FSEvents. Directory changes enumerate that subtree.
    public func synchronizeChanges(_ changed: [URL]) async throws -> LibraryState {
        try await reconcileChanges(changed)
    }
}

/// Foundation can present /var and /private/var aliases differently across enumeration/reload.
/// Resolve the parent with POSIX realpath while leaving the final component un-followed.
func stableChangeURL(_ url: URL) -> URL {
    let parent = url.deletingLastPathComponent()
    guard let pointer = realpath(parent.path, nil) else { return url.standardizedFileURL }
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer), isDirectory: true).appendingPathComponent(url.lastPathComponent)
}

func syncContains(_ parent: URL, _ child: URL) -> Bool {
    let p = parent.path, c = child.path
    return c == p || c.hasPrefix(p == "/" ? "/" : p + "/")
}
