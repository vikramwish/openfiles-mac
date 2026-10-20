import Foundation
import Vision
import ImageIO

public struct ImageSubject: Codable, Hashable, Sendable {
    public let name: String
    public let confidence: Float
}

public struct ImageContentIndex: Codable, Hashable, Sendable {
    public let revision: String
    public let subjects: [ImageSubject]
    public let textTerms: [String]
    public var location: PhotoLocation? = nil
    public var subjectTerms: Set<String> { Set(subjects.flatMap { FileSearchQuery.words($0.name) }) }
}

/// Background-only, local pixel analysis. Source files are never rewritten or uploaded.
enum NativeImageContent {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
    static var revision: String { "vision-c\(VNClassifyImageRequest.currentRevision)-ocr\(VNRecognizeTextRequest.currentRevision)-2048-025-location-v2" }
    static func extract(_ url: URL, size: Int64) throws -> ExtractedText {
        guard size <= 50 * 1024 * 1024 else { return ExtractedText(detail: "Filename only: image exceeds 50 MB") }
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw OpenFilesError.message("Image could not be decoded") }
            let classification = VNClassifyImageRequest()
            classification.preferBackgroundProcessing = true
            let text = VNRecognizeTextRequest()
            text.preferBackgroundProcessing = true
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = false
            text.minimumTextHeight = 0.01
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            // Keep embedded photo metadata available even when an optional Vision model
            // cannot run on this machine or for this image. Each analysis is independent.
            try? handler.perform([classification])
            try? handler.perform([text])
            let subjects = (classification.results ?? []).filter { $0.confidence >= 0.25 }
                .sorted { $0.confidence > $1.confidence }.prefix(12)
                .map { ImageSubject(name: $0.identifier.replacingOccurrences(of: "_", with: " "), confidence: $0.confidence) }
            let recognized = String((text.results ?? []).compactMap { observation -> String? in
                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.5 else { return nil }
                return candidate.string
            }.joined(separator: "\n").prefix(12000))
            let content = ImageContentIndex(revision: revision, subjects: subjects, textTerms: Array(Set(FileSearchQuery.words(recognized).prefix(6000))).sorted(), location: PhotoLocation.read(source))
            let searchable = (subjects.map(\.name) + [recognized]).joined(separator: "\n")
            return ExtractedText(text: searchable, bytes: size, read: true,
                detail: "Image content: \(subjects.count) subjects + \(content.textTerms.count) OCR terms · on device · 2048 px thumbnail", imageContent: content)
        }
    }
}
