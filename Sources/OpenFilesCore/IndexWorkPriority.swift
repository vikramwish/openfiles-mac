import Foundation

/// Native file browsing and Spotlight remain available for generated documentation.
enum GeneratedDocumentation {
    static func contains(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent("doxygen.css").path) &&
            (fm.fileExists(atPath: folder.appendingPathComponent("dynsections.js").path) ||
             fm.fileExists(atPath: folder.appendingPathComponent("navtree.js").path))
    }
}

enum IndexWorkPriority {
    static func rank(_ url: URL, project: Bool) -> Int {
        if project { return 3 }
        switch url.pathExtension.lowercased() {
        case "pdf", "txt", "md", "rtf", "csv", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp": return 0
        case "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp": return 1
        case "html", "css", "js", "ts", "tsx", "swift", "py", "json", "xml", "yaml", "yml": return 4
        default: return 2
        }
    }
}
