import Foundation

/// Default read-only discovery covers accessible user data and mounted data volumes.
/// System installations and sealed OS volumes are deliberately not traversed.
public enum MacScanScopes {
    public static func defaults(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let fm = FileManager.default
        var roots = [home]
        if home.standardizedFileURL == fm.homeDirectoryForCurrentUser.standardizedFileURL {
            roots.append(URL(fileURLWithPath: "/Users", isDirectory: true))
            let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey], options: [.skipHiddenVolumes]) ?? []
            roots += volumes.filter {
                $0.path.hasPrefix("/Volumes/") &&
                (try? $0.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
            }
        }
        return reduce(roots.filter { fm.fileExists(atPath: $0.path) })
    }
    public static func reduce(_ roots: [URL]) -> [URL] {
        var kept: [URL] = []
        let normalized: [URL] = roots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        let ordered: [URL] = Set(normalized).sorted { lhs, rhs in
            if lhs.path.count == rhs.path.count { return lhs.path < rhs.path }
            return lhs.path.count < rhs.path.count
        }
        for root in ordered {
            if !kept.contains(where: { FileRules.contains($0, root) }) { kept.append(root) }
        }
        return kept
    }
}
