import Foundation
import Vision
import ImageIO
import CoreGraphics

/// A revision-pinned on-device visual description, separate from byte fingerprints.
public struct PhotoVisualSignature: @unchecked Sendable {
    private let observation: VNFeaturePrintObservation
    fileprivate init(_ observation: VNFeaturePrintObservation) { self.observation = observation }
    public func distance(to other: Self) throws -> Float {
        guard observation.requestRevision == other.observation.requestRevision,
              observation.elementCount == other.observation.elementCount else {
            throw OpenFilesError.message("Visual descriptions use different analysis versions. Analyze the photos again.")
        }
        var result: Float = 0
        try observation.computeDistance(&result, to: other.observation)
        guard result.isFinite && result >= 0 else { throw OpenFilesError.message("Image comparison returned an invalid distance.") }
        return result
    }
}

public enum PhotoVisualAnalysis {
    public static func signature(at url: URL) throws -> PhotoVisualSignature {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024
              ] as CFDictionary) else { throw OpenFilesError.message("This photo could not be decoded for visual comparison.") }
        return try signature(image: image)
    }
    public static func signature(image: CGImage) throws -> PhotoVisualSignature {
        try autoreleasepool {
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = VNGenerateImageFeaturePrintRequestRevision2
            request.imageCropAndScaleOption = .scaleFit
            request.preferBackgroundProcessing = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            guard let observation = request.results?.first else { throw OpenFilesError.message("Visual comparison isn’t available for this image.") }
            return PhotoVisualSignature(observation)
        }
    }
}

public struct PhotoSimilarityGroup: Identifiable, Sendable {
    public let referenceID: String
    public let photoIDs: [String]
    public var id: String { referenceID }
}

/// Vantage-point radius search avoids comparing every image with every other image.
/// Each group is anchored to one reference; similarity never chains through weaker links.
public enum PhotoSimilarity {
    private final class Node {
        let pivot: String
        let boundary: Float
        let inner: Node?
        let outer: Node?
        init(pivot: String, boundary: Float, inner: Node?, outer: Node?) {
            self.pivot = pivot; self.boundary = boundary; self.inner = inner; self.outer = outer
        }
    }
    public static func groups(ids: [String], radius: Float = 0.25, distance: (String, String) throws -> Float) throws -> [PhotoSimilarityGroup] {
        guard radius.isFinite, radius >= 0 else { throw OpenFilesError.message("Choose a valid visual match range.") }
        let ids = Array(Set(ids)).sorted()
        func measured(_ a: String, _ b: String) throws -> Float {
            try Task.checkCancellation()
            let result = try distance(a, b)
            guard result.isFinite && result >= 0 else { throw OpenFilesError.message("Invalid visual comparison.") }
            return result
        }
        func build(_ ids: [String]) throws -> Node? {
            try Task.checkCancellation()
            guard let pivot = ids.last else { return nil }
            let distances: [(String, Float)] = try ids.dropLast().map { id in (id, try measured(pivot, id)) }
            let sorted = distances.sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1 }
            let middle = sorted.count / 2
            let boundary = sorted.isEmpty ? 0 : sorted[middle].1
            return Node(pivot: pivot, boundary: boundary,
                        inner: try build(Array(sorted.prefix(middle).map { $0.0 })),
                        outer: try build(Array(sorted.dropFirst(middle).map { $0.0 })))
        }
        let root = try build(ids)
        func matches(_ node: Node?, target: String, result: inout [(String, Float)]) throws {
            try Task.checkCancellation()
            guard let node else { return }
            let d = try measured(target, node.pivot)
            if d <= radius { result.append((node.pivot, d)) }
            if d - radius <= node.boundary { try matches(node.inner, target: target, result: &result) }
            if d + radius >= node.boundary { try matches(node.outer, target: target, result: &result) }
        }
        var assigned = Set<String>(), result: [PhotoSimilarityGroup] = []
        for reference in ids where !assigned.contains(reference) {
            try Task.checkCancellation()
            var candidates: [(String, Float)] = []
            try matches(root, target: reference, result: &candidates)
            let neighbors = candidates.filter { $0.0 != reference && !assigned.contains($0.0) }
                .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.map { $0.0 }
            guard !neighbors.isEmpty else { continue }
            let members = [reference] + neighbors
            assigned.formUnion(members)
            result.append(.init(referenceID: reference, photoIDs: members))
        }
        return result
    }
}
