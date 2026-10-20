import Foundation
import CoreGraphics
import ImageIO

/// One piece of a multimodal user message. Vision models receive image previews as
/// base64 data URLs; nothing is uploaded anywhere except the configured model endpoint.
public enum AgentContentPart: Sendable {
    case text(String)
    /// A downscaled JPEG preview encoded for the OpenAI-compatible `image_url` format.
    case imageData(mediaType: String, base64: String)

    func jsonObject() -> [String: Any] {
        switch self {
        case .text(let text):
            return ["type": "text", "text": text]
        case .imageData(let mediaType, let base64):
            return ["type": "image_url", "image_url": ["url": "data:\(mediaType);base64,\(base64)"]]
        }
    }
}

/// Downscales an image file to a bounded JPEG preview so screenshots can be renamed from
/// what they show without sending multi-megabyte originals. Reading and scaling happens
/// on the caller's thread; keep it off the main actor.
public enum AgentImagePreview {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "bmp", "tiff"]

    /// Returns the base64 JPEG and its media type, or nil when the file cannot be read or scaled.
    public static func downscale(path: String, maxDimension: Int = 1024, quality: Double = 0.6) -> (base64: String, mediaType: String)? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        guard !output.isEmpty else { return nil }
        return (output.base64EncodedString(), "image/jpeg")
    }

    /// Whether a file is a plausible vision target: a recognized image extension that is not huge.
    public static func isVisionCandidate(path: String, bytes: Int64, maxBytes: Int64 = 10 * 1024 * 1024) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext) && bytes > 0 && bytes <= maxBytes
    }
}
