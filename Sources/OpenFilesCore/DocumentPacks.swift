import Foundation
import CryptoKit
import Darwin

public struct DocumentPackAttachment: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var url: URL
    public var reviewed: Bool
    /// The exact bytes the user reviewed. A later edit requires another review.
    public var reviewedDigest: String?
    public init(id: UUID = UUID(), url: URL, reviewed: Bool = false, reviewedDigest: String? = nil) {
        self.id = id; self.url = url; self.reviewed = reviewed; self.reviewedDigest = reviewedDigest
    }
}

public struct DocumentPackItem: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var query: String
    public var required: Bool
    public var attachments: [DocumentPackAttachment]
    public init(id: UUID = UUID(), title: String, detail: String = "", query: String = "", required: Bool = true, attachments: [DocumentPackAttachment] = []) {
        self.id = id; self.title = title; self.detail = detail; self.query = query
        self.required = required; self.attachments = attachments
    }
}

public struct DocumentPack: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var templateID: String
    public var created: Date
    public var items: [DocumentPackItem]
    public init(id: UUID = UUID(), title: String, templateID: String = "custom", created: Date = Date(), items: [DocumentPackItem] = []) {
        self.id = id; self.title = title; self.templateID = templateID; self.created = created; self.items = items
    }
    public var attachmentCount: Int { items.reduce(0) { $0 + $1.attachments.count } }
    public var missingRequiredCount: Int { items.filter { $0.required && $0.attachments.isEmpty }.count }
    public var reviewedCount: Int { items.flatMap(\.attachments).filter { $0.reviewed && $0.reviewedDigest != nil }.count }
}

public struct DocumentPackTemplate: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let detail: String
    public let symbol: String
    public let items: [DocumentPackItem]
    public func makePack() -> DocumentPack {
        DocumentPack(title: title, templateID: id, items: items.map {
            DocumentPackItem(title: $0.title, detail: $0.detail, query: $0.query, required: $0.required)
        })
    }
    public static let rental = DocumentPackTemplate(id: "rental", title: "Rental application", detail: "Gather identity, income and rental documents.", symbol: "house", items: [
        DocumentPackItem(title: "Proof of identity", detail: "Choose only the identity documents the recipient requests.", query: "identity, passport, licence"),
        DocumentPackItem(title: "Proof of income", detail: "Check the requested date range and redact information you do not need to share.", query: "payslip, income, employment"),
        DocumentPackItem(title: "Rental history", detail: "Add a reference or rental statement if requested.", query: "rental, reference, lease", required: false)
    ])
    public static let expenses = DocumentPackTemplate(id: "expenses", title: "Expense claim", detail: "Bring receipts and supporting evidence together.", symbol: "receipt", items: [
        DocumentPackItem(title: "Receipts", detail: "Check the amount, date and business purpose for each expense.", query: "receipt, invoice, expense"),
        DocumentPackItem(title: "Claim form", detail: "Use the form supplied by your employer or client.", query: "expense, claim, reimbursement"),
        DocumentPackItem(title: "Supporting documents", detail: "Add approvals, booking confirmations or other requested evidence.", query: "booking, approval, confirmation", required: false)
    ])
    public static let travel = DocumentPackTemplate(id: "travel", title: "Travel documents", detail: "Keep the documents for a trip in one place.", symbol: "airplane", items: [
        DocumentPackItem(title: "Bookings and itinerary", detail: "Check the traveller names, destinations and dates.", query: "booking, itinerary, ticket"),
        DocumentPackItem(title: "Travel insurance", detail: "Check coverage and travel dates with your provider.", query: "travel insurance, insurance policy", required: false),
        DocumentPackItem(title: "Identity and entry documents", detail: "Check current requirements with the relevant authorities before travelling.", query: "passport, visa", required: false)
    ])
    public static let custom = DocumentPackTemplate(id: "custom", title: "My document pack", detail: "Start with your own checklist.", symbol: "folder.badge.plus", items: [
        DocumentPackItem(title: "Documents", detail: "Add the documents needed for your task.")
    ])
    public static let examples: [DocumentPackTemplate] = [rental, expenses, travel, custom]
    public static let disclaimer = "These are editable starting points, not official requirements. Check the recipient’s checklist and current requirements. OpenFiles does not verify legal validity, expiry dates or acceptance."
}

/// Stores checklist metadata only. Originals are read only after an explicit attachment or review action.
public actor DocumentPackStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory.standardizedFileURL }

    public func load() throws -> [DocumentPack] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let directoryFD = try PackFiles.openDirectory(directory); defer { close(directoryFD) }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { url in
                let fd = try PackFiles.openRegular(url); defer { close(fd) }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                let pack = try JSONDecoder().decode(DocumentPack.self, from: handle.readToEnd() ?? Data())
                try validate(pack)
                guard url.deletingPathExtension().lastPathComponent == pack.id.uuidString else {
                    throw OpenFilesError.message("A document pack’s saved metadata does not match its filename.")
                }
                return pack
            }.sorted { $0.created > $1.created }
    }

    public func save(_ pack: DocumentPack) throws {
        try validate(pack)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = try PackFiles.openDirectory(directory); defer { close(fd) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(pack)
        let temporaryName = ".\(UUID().uuidString).tmp"
        let temporaryFD = openat(fd, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard temporaryFD >= 0 else { throw PackFiles.error("Could not save the document pack") }
        defer { close(temporaryFD); unlinkat(fd, temporaryName, 0) }
        try PackFiles.write(data, to: temporaryFD)
        guard fsync(temporaryFD) == 0,
              renameat(fd, temporaryName, fd, "\(pack.id.uuidString).json") == 0 else {
            throw PackFiles.error("Could not finish saving the document pack")
        }
    }

    public func delete(_ id: UUID) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let fd = try PackFiles.openDirectory(directory); defer { close(fd) }
        guard unlinkat(fd, "\(id.uuidString).json", 0) == 0 || errno == ENOENT else {
            throw PackFiles.error("Could not remove the document pack")
        }
    }

    public func attach(_ url: URL, to itemID: UUID, in pack: DocumentPack) throws -> DocumentPack {
        guard let index = pack.items.firstIndex(where: { $0.id == itemID }) else { throw OpenFilesError.message("Checklist item not found.") }
        let fd = try PackFiles.openRegular(url); close(fd)
        var updated = pack
        let source = PackFiles.normalized(url)
        if !updated.items[index].attachments.contains(where: { PackFiles.normalized($0.url) == source }) {
            updated.items[index].attachments.append(DocumentPackAttachment(url: source))
        }
        try save(updated)
        return updated
    }

    public func removeAttachment(_ id: UUID, in pack: DocumentPack) throws -> DocumentPack {
        var updated = pack
        for index in updated.items.indices { updated.items[index].attachments.removeAll { $0.id == id } }
        try save(updated)
        return updated
    }

    public func review(_ attachmentID: UUID, in pack: DocumentPack) throws -> DocumentPack {
        var updated = pack
        guard let item = updated.items.firstIndex(where: { $0.attachments.contains(where: { $0.id == attachmentID }) }),
              let attachment = updated.items[item].attachments.firstIndex(where: { $0.id == attachmentID }) else {
            throw OpenFilesError.message("Attachment not found.")
        }
        updated.items[item].attachments[attachment].reviewedDigest = try PackFiles.digest(updated.items[item].attachments[attachment].url)
        updated.items[item].attachments[attachment].reviewed = true
        try save(updated)
        return updated
    }

    public func reviewAll(_ pack: DocumentPack) throws -> DocumentPack {
        var updated = pack
        for item in updated.items.indices {
            for attachment in updated.items[item].attachments.indices {
                updated.items[item].attachments[attachment].reviewedDigest = try PackFiles.digest(updated.items[item].attachments[attachment].url)
                updated.items[item].attachments[attachment].reviewed = true
            }
        }
        try save(updated)
        return updated
    }

    /// Export is deliberately all-or-nothing. Incomplete checklist items are disclosed; unreviewed or changed files abort the export.
    public func export(_ pack: DocumentPack, to parent: URL) throws -> URL {
        try validate(pack)
        for attachment in pack.items.flatMap(\.attachments) {
            guard attachment.reviewed, attachment.reviewedDigest != nil else {
                throw OpenFilesError.message("Review \(attachment.url.lastPathComponent) before exporting this pack.")
            }
        }
        let parentFD = try PackFiles.openDirectory(parent); defer { close(parentFD) }
        let name = "\(PackFiles.safeName(pack.title)) - \(UUID().uuidString)"
        guard mkdirat(parentFD, name, mode_t(0o700)) == 0 else { throw PackFiles.error("Could not create a new export folder") }
        let output = PackFiles.normalized(parent).appendingPathComponent(name, isDirectory: true)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: output) } }
        let outputFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard outputFD >= 0 else { throw PackFiles.error("Could not open the export folder") }
        defer { close(outputFD) }
        var checklist = ["\(PackFiles.singleLine(pack.title))", "", DocumentPackTemplate.disclaimer, "", "Exported \(Date().formatted(date: .abbreviated, time: .shortened))", "Files are copies of the exact content reviewed in OpenFiles. Originals were not moved or edited.", ""]
        for (index, item) in pack.items.enumerated() {
            let title = PackFiles.singleLine(item.title)
            let status = item.attachments.isEmpty ? (item.required ? "MISSING — required by this checklist" : "Not supplied — optional") : "Included — reviewed"
            checklist.append("\(index + 1). \(title): \(status)")
            if !item.detail.isEmpty { checklist.append("   \(PackFiles.singleLine(item.detail))") }
            if item.attachments.isEmpty { checklist.append(""); continue }
            let folderName = String(format: "%02d", index + 1) + " - " + PackFiles.safeName(item.title)
            guard mkdirat(outputFD, folderName, mode_t(0o700)) == 0 else { throw PackFiles.error("Could not create a checklist folder") }
            let itemFD = openat(outputFD, folderName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard itemFD >= 0 else { throw PackFiles.error("Could not open a checklist folder") }
            defer { close(itemFD) }
            for (attachmentIndex, attachment) in item.attachments.enumerated() {
                let filename = String(format: "%02d", attachmentIndex + 1) + " - " + PackFiles.safeName(attachment.url.lastPathComponent, limit: 150)
                try PackFiles.copyReviewed(attachment, into: itemFD, name: filename)
                checklist.append("   \(folderName)/\(filename)")
            }
            checklist.append("")
        }
        checklist += ["Missing checklist items: \(pack.missingRequiredCount)", "Review the checklist before sharing. A file’s presence does not establish that it meets the recipient’s requirements.", ""]
        let readmeFD = openat(outputFD, "README.txt", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard readmeFD >= 0 else { throw PackFiles.error("Could not write the export checklist") }
        defer { close(readmeFD) }
        try PackFiles.write(Data(checklist.joined(separator: "\n").utf8), to: readmeFD)
        // A source may change while a later attachment is being copied. Check every source once more before reporting success.
        for attachment in pack.items.flatMap(\.attachments) {
            guard try PackFiles.digest(attachment.url) == attachment.reviewedDigest else { throw PackFiles.stale(attachment.url) }
        }
        completed = true
        return output
    }

    private func validate(_ pack: DocumentPack) throws {
        guard !pack.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(pack.items.map(\.id)).count == pack.items.count,
              Set(pack.items.flatMap(\.attachments).map(\.id)).count == pack.attachmentCount,
              pack.items.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              pack.items.flatMap(\.attachments).allSatisfy({ $0.url.isFileURL }) else {
            throw OpenFilesError.message("Document packs need a title, named checklist items and valid local file attachments.")
        }
    }
}

/// All path components are opened without following symbolic links. File descriptors keep reads and writes bound to the checked files.
private enum PackFiles {
    static func error(_ action: String) -> OpenFilesError { .message("\(action): \(String(cString: strerror(errno))).") }
    static func stale(_ url: URL) -> OpenFilesError { .message("\(url.lastPathComponent) changed after review. Preview and review it again before exporting.") }
    static func normalized(_ url: URL) -> URL {
        // macOS exposes its temporary directory through these two system aliases.
        let path = url.standardizedFileURL.path
        if path == "/tmp" || path.hasPrefix("/tmp/") || path == "/var" || path.hasPrefix("/var/") {
            return URL(fileURLWithPath: "/private" + path)
        }
        return url.standardizedFileURL
    }
    static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw OpenFilesError.message("Choose a valid local folder.") }
        let components = normalized(url).pathComponents.filter { $0 != "/" }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw error("Could not access the local filesystem") }
        for component in components {
            let child = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard child >= 0 else { throw OpenFilesError.message("Choose a local folder without symbolic links: \(url.lastPathComponent).") }
            fd = child
        }
        return fd
    }
    static func openRegular(_ url: URL) throws -> Int32 {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw OpenFilesError.message("Choose a valid local file.") }
        let source = normalized(url)
        let parentFD = try openDirectory(source.deletingLastPathComponent()); defer { close(parentFD) }
        // Inspect flags before open so checking an evicted File Provider item does not request its contents.
        var metadata = stat()
        guard fstatat(parentFD, source.lastPathComponent, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw OpenFilesError.message("Cannot find \(source.lastPathComponent). Check that it is available on this Mac.")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw OpenFilesError.message("Only regular files can be attached to document packs. Symbolic links and folders are excluded.")
        }
        guard (metadata.st_flags & UInt32(SF_DATALESS)) == 0 else {
            throw OpenFilesError.message("Download \(source.lastPathComponent) to this Mac before using it.")
        }
        let cloud = try source.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard !source.lastPathComponent.lowercased().hasSuffix(".icloud"),
              !(cloud.isUbiquitousItem == true && cloud.ubiquitousItemDownloadingStatus != .current && cloud.ubiquitousItemDownloadingStatus != .downloaded) else {
            throw OpenFilesError.message("Download \(source.lastPathComponent) to this Mac before adding or exporting it.")
        }
        // O_NONBLOCK ensures a FIFO or another special file cannot hang the actor before fstat rejects it.
        let fd = openat(parentFD, source.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw OpenFilesError.message("Cannot read \(source.lastPathComponent). Check that it exists locally and is not a symbolic link.") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd); throw OpenFilesError.message("Only regular files can be attached to document packs.")
        }
        // SF_DATALESS marks evicted File Provider content, including non-iCloud providers.
        guard (info.st_flags & UInt32(SF_DATALESS)) == 0 else {
            close(fd); throw OpenFilesError.message("Download \(source.lastPathComponent) to this Mac before using it.")
        }
        return fd
    }
    static func same(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size &&
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
    static func readHash(_ fd: Int32, copyingTo output: Int32? = nil) throws -> String {
        var hash = SHA256()
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
            if let output { try write(chunk, to: output) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func digest(_ url: URL) throws -> String {
        let fd = try openRegular(url); defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0 else { throw error("Could not inspect the file") }
        let result = try readHash(fd)
        let current = try openRegular(url); defer { close(current) }
        guard fstat(current, &after) == 0, same(before, after) else { throw stale(url) }
        return result
    }
    static func copyReviewed(_ attachment: DocumentPackAttachment, into directory: Int32, name: String) throws {
        let source = try openRegular(attachment.url); defer { close(source) }
        var before = stat(), after = stat()
        guard fstat(source, &before) == 0 else { throw error("Could not inspect the source file") }
        let destination = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard destination >= 0 else { throw error("Could not create a document copy") }
        defer { close(destination) }
        let copiedHash = try readHash(source, copyingTo: destination)
        guard copiedHash == attachment.reviewedDigest,
              fstat(source, &after) == 0, same(before, after) else { throw stale(attachment.url) }
        guard fsync(destination) == 0, lseek(destination, 0, SEEK_SET) >= 0 else { throw error("Could not verify the document copy") }
        guard try readHash(destination) == copiedHash else { throw OpenFilesError.message("Document copy verification failed. Nothing was exported.") }
    }
    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw error("Could not write the document data") }
                offset += count
            }
        }
    }
    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters).joined(separator: " ")
    }
    static func safeName(_ text: String, limit: Int = 60) -> String {
        let cleaned = singleLine(text).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Documents" : String(cleaned.prefix(limit))
    }
}
