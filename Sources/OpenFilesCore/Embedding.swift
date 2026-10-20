import Foundation
import NaturalLanguage
import Accelerate
import CryptoKit
import PDFKit

public protocol EmbeddingBackend: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var acceptsLegacyVectors: Bool { get }
    /// Document embeddings and retrieval queries can require different task prompts.
    func vector(for text: String) async -> [Double]?
    func queryVector(for text: String) async -> [Double]?
    func failureReason() async -> String?
}

public extension EmbeddingBackend {
    var displayName: String { identifier }
    var acceptsLegacyVectors: Bool { false }
    func queryVector(for text: String) async -> [Double]? { await vector(for: text) }
    func failureReason() async -> String? { nil }
}

/// Own one model per bounded worker. Apple's API controls its internal tokenizer/compute units.
public actor NativeEmbeddingBackend: EmbeddingBackend {
    public nonisolated let identifier: String
    public nonisolated let displayName = "Apple NaturalLanguage · English sentence embedding"
    public nonisolated let acceptsLegacyVectors = true
    private var embedding: NLEmbedding?
    private var loaded = false
    public init() { identifier = "apple-nl-en-r\(NLEmbedding.currentSentenceEmbeddingRevision(for: .english))-prep2" }
    public func vector(for text: String) -> [Double]? {
        if !loaded { embedding = NLEmbedding.sentenceEmbedding(for: .english); loaded = true }
        return embedding?.vector(for: text)
    }
    public func queryVector(for text: String) -> [Double]? {
        // Preserve the original Apple backend's query preparation.
        vector(for: FileSearchQuery(text).text)
    }
}

public enum VectorMath {
    public static func dot(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return vDSP.dot(a, b)
    }
    public static func normalized(_ vector: [Double]) -> [Double] {
        let norm = sqrt(dot(vector, vector))
        return norm > 0 ? vDSP.divide(vector, norm) : vector
    }
    public static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        let norm = sqrt(dot(a, a) * dot(b, b))
        return norm > 0 ? dot(a, b) / norm : 0
    }
}

struct ExtractedText: Sendable {
    var text = ""
    var bytes: Int64 = 0
    var read = false
    var detail = "Filename only: unsupported content format"
    var imageContent: ImageContentIndex? = nil
}

enum IndexText {
    static let maxInputCharacters = 4000
    static func extract(_ url: URL, size: Int64) throws -> ExtractedText {
        let cloud = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if cloud.isUbiquitousItem == true && cloud.ubiquitousItemDownloadingStatus == .notDownloaded { return ExtractedText(detail: "Filename only: cloud file is not downloaded") }
        if NativeImageContent.extensions.contains(url.pathExtension.lowercased()) { return try NativeImageContent.extract(url, size: size) }
        guard size <= 5 * 1024 * 1024 else { return ExtractedText(detail: "Filename only: content exceeds 5 MB") }
        if url.pathExtension.lowercased() == "pdf" {
            return autoreleasepool {
                guard let pdf = PDFDocument(url: url), !pdf.isLocked else { return ExtractedText(detail: "Filename only: PDF is locked or unreadable") }
                var text = ""
                for index in 0..<min(pdf.pageCount, 20) {
                    text += (pdf.page(at: index)?.string ?? "") + "\n"
                    if text.count >= 12000 { break }
                }
                return ExtractedText(text: String(text.prefix(12000)), bytes: size, read: true, detail: "PDF text: up to 20 pages / 12,000 characters")
            }
        }
        guard FileRules.textExtensions.contains(url.pathExtension.lowercased()) else { return ExtractedText() }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        // Bound I/O before decoding/tokenizing; never load a whole 5 MB text file to use its prefix.
        let data = try handle.read(upToCount: 64 * 1024) ?? Data()
        return ExtractedText(text: String(String(decoding: data, as: UTF8.self).prefix(12000)), bytes: Int64(data.count), read: true, detail: "Text prefix: up to 64 KiB read / 12,000 characters")
    }
    static func prepare(_ text: String) -> String { String(text.prefix(maxInputCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) }
    static func key(_ text: String, engine: String) -> String {
        SHA256.hash(data: Data((engine + "\0" + text).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct EmbeddingObject: Codable, Sendable {
    var engine: String
    var vector: [Double]?
    var wordUnits: Int
    var inputCharacters: Int
    var tokenizationSeconds: Double = 0
    var embeddingSeconds: Double = 0
}

/// Content-addressed immutable objects. Concurrent duplicate requests share one inference task.
actor EmbeddingObjects {
    private let directory: URL
    private var memory: [String: EmbeddingObject] = [:]
    private var flights: [String: Task<EmbeddingObject, Never>] = [:]
    init(directory: URL) { self.directory = directory }
    func lookup(_ key: String, engine: String) -> EmbeddingObject? {
        if let object = memory[key], object.engine == engine { return object }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")), let object = try? JSONDecoder().decode(EmbeddingObject.self, from: data), object.engine == engine, let vector = object.vector, !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        memory[key] = object; return object
    }
    func resolve(_ key: String, engine: String, build: @escaping @Sendable () async -> EmbeddingObject) async throws -> (EmbeddingObject, Bool) {
        if let cached = lookup(key, engine: engine) { return (cached, true) }
        if let flight = flights[key] { return (await flight.value, true) }
        let task = Task { await build() }; flights[key] = task
        let object = await task.value; flights[key] = nil
        if object.vector != nil {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(key + ".json")
            try JSONEncoder().encode(object).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            memory[key] = object
        }
        return (object, false)
    }
}
