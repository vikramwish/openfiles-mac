import Foundation

/// Display location only: a local provider folder does not prove a file is uploaded or available offline.
public struct FileStorageLocation: Equatable, Sendable {
    public let label: String
    public let symbol: String
    public let path: String
    public let isRemote: Bool

    public static func remote(provider: CloudProvider, folders: [String] = []) -> Self {
        Self(label: provider.displayName, symbol: "cloud", path: ([provider.displayName] + folders).joined(separator: " / "), isRemote: true)
    }

    public static func local(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        let components = url.standardizedFileURL.pathComponents
        let homeParts = home.standardizedFileURL.pathComponents
        var label = "This Mac", symbol = "internaldrive"
        if components.starts(with: homeParts) {
            let relative = Array(components.dropFirst(homeParts.count))
            if relative.starts(with: ["Library", "Mobile Documents", "com~apple~CloudDocs"]) {
                label = "iCloud Drive"; symbol = "icloud"
            } else if relative.count >= 3, relative[0] == "Library", relative[1] == "CloudStorage" {
                let folder = relative[2]
                if folder == "OneDrive" || folder.hasPrefix("OneDrive-") { label = "OneDrive"; symbol = "cloud" }
                else if folder == "GoogleDrive" || folder.hasPrefix("GoogleDrive-") { label = "Google Drive"; symbol = "cloud" }
            }
        } else if components.count >= 3, components[1] == "Volumes" {
            label = components[2]; symbol = "externaldrive"
        }
        return Self(label: label, symbol: symbol, path: url.deletingLastPathComponent().path, isRemote: false)
    }
}
