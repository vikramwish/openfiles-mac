import Foundation
import CoreGraphics
import ImageIO
import OpenFilesCore

struct PhotoSimilarityChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Visual review finds close pairs without chaining unrelated ends", anchored),
        ("Visual radius search scales without an all-pairs scan", indexed),
        ("Visual comparison rejects invalid measurements and supports cancellation", validation),
        ("Vision identifies a slightly cropped photo as visually similar", nativeCrop)
    ]
    static func anchored() async throws {
        let positions: [String: Float] = ["a": 0, "b": 0.15, "c": 0.30, "d": 2, "e": 2.1]
        let groups = try PhotoSimilarity.groups(ids: Array(positions.keys) + ["a"], radius: 0.2) { abs(positions[$0]! - positions[$1]!) }
        checkEqual(groups.count, 2)
        checkEqual(groups.first?.photoIDs, ["a", "b"])
        checkEqual(groups.last?.photoIDs, ["d", "e"])
        checkFalse(groups.flatMap(\.photoIDs).contains("c"))
        for group in groups {
            checkTrue(group.photoIDs.allSatisfy { abs(positions[group.referenceID]! - positions[$0]!) <= 0.2 })
        }
        // Visual suggestions are a separate type and never become exact-byte duplicate groups.
        checkTrue(PhotoDuplicates.groups([]).isEmpty)
    }
    static func indexed() async throws {
        var positions: [String: Float] = [:]
        for index in 0..<500 {
            positions[String(format: "%04d-a", index)] = Float(index) * 2
            positions[String(format: "%04d-b", index)] = Float(index) * 2 + 0.05
        }
        var comparisons = 0
        let groups = try PhotoSimilarity.groups(ids: Array(positions.keys), radius: 0.1) { a, b in
            comparisons += 1; return abs(positions[a]! - positions[b]!)
        }
        checkEqual(groups.count, 500); checkTrue(groups.allSatisfy { $0.photoIDs.count == 2 })
        checkTrue(comparisons < 100_000)
    }
    static func validation() async throws {
        for radius: Float in [-1, .nan, .infinity] {
            do { _ = try PhotoSimilarity.groups(ids: ["a", "b"], radius: radius) { _, _ in 0 }; failCheck("Invalid match range accepted") } catch {}
        }
        do { _ = try PhotoSimilarity.groups(ids: ["a", "b"]) { _, _ in .nan }; failCheck("Invalid distance accepted") } catch {}
        let job = Task { try PhotoSimilarity.groups(ids: ["a", "b"]) { _, _ in 0 } }; job.cancel()
        do { _ = try await job.value; failCheck("Cancelled visual review completed") } catch is CancellationError {} catch { failCheck(error.localizedDescription) }
    }
    static func nativeCrop() async throws {
        guard let url = Bundle.module.url(forResource: "sample-animal", withExtension: "jpg", subdirectory: "Fixtures"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let crop = image.cropping(to: CGRect(x: Double(image.width) * 0.025, y: Double(image.height) * 0.025, width: Double(image.width) * 0.95, height: Double(image.height) * 0.95)) else {
            throw OpenFilesError.message("Missing visual similarity fixture")
        }
        let original = try PhotoVisualAnalysis.signature(image: image)
        let cropped = try PhotoVisualAnalysis.signature(image: crop)
        let identical = try PhotoVisualAnalysis.signature(at: url)
        let identicalDistance = try original.distance(to: identical), cropDistance = try original.distance(to: cropped)
        print("Vision fixture distances · same \(identicalDistance) · crop \(cropDistance)")
        checkTrue(identicalDistance <= 0.25)
        checkTrue(cropDistance <= 0.25)
        guard let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw OpenFilesError.message("Could not create contrast fixture") }
        for y in 0..<8 {
            for x in 0..<8 {
                context.setFillColor(CGColor(red: (x + y) % 2 == 0 ? 1 : 0, green: 0, blue: (x + y) % 2 == 0 ? 0 : 1, alpha: 1))
                context.fill(CGRect(x: x * 16, y: y * 16, width: 16, height: 16))
            }
        }
        guard let graphic = context.makeImage() else { throw OpenFilesError.message("Missing contrast fixture") }
        let unrelated = try PhotoVisualAnalysis.signature(image: graphic)
        checkTrue(try original.distance(to: unrelated) > 0.4)
        let groups = try PhotoSimilarity.groups(ids: ["original", "crop"]) { a, b in a == b ? 0 : cropDistance }
        checkEqual(groups.count, 1)
    }
}
