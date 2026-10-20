import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import OpenFilesCore

private struct ImageTestEmbedding: EmbeddingBackend {
    let identifier = "image-test-no-text-model-v1"
    func vector(for text: String) async -> [Double]? { nil }
}

struct ImageContentChecks {
    static let scenarios: [(String, () async throws -> Void)] = [
        ("Visual subject search, OCR, cache, persistence, and read-only image analysis", imageSearch)
    ]
    static func imageSearch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesImage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Pictures"), data = base.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let source = Bundle.module.url(forResource: "sample-animal", withExtension: "jpg", subdirectory: "Fixtures") else { throw OpenFilesError.message("Missing public-domain image fixture") }
        let photo = root.appendingPathComponent("IMG_0042.jpg")
        let original = try Data(contentsOf: source); try original.write(to: photo)
        let before = try photo.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let screenshot = root.appendingPathComponent("IMG_0043.png")
        try makeTextImage(screenshot)
        let library = FileLibrary(directory: data, embeddingFactory: { ImageTestEmbedding() })
        _ = try await library.load(); try await library.addRoot(root)
        let cold = try await library.scan()
        let images = library.searchCatalog.matches("images of a zebra")
        checkEqual(images.count, 1); checkEqual(images.first?.file.name, photo.lastPathComponent)
        checkEqual(images.first?.reason, "Image subject match")
        checkTrue(images.first?.file.imageContent?.subjects.contains { $0.name.lowercased().contains("zebra") && $0.confidence >= 0.25 } == true)
        checkEqual(library.searchCatalog.matches("pictures of zebras").first?.file.name, photo.lastPathComponent)
        checkEqual(library.searchCatalog.matches("orbital").first?.file.name, screenshot.lastPathComponent)
        checkEqual(library.searchCatalog.matches("zebra pdfs").count, 0)
        checkEqual(try Data(contentsOf: photo), original)
        checkEqual(try photo.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before)
        let warm = try await library.scan()
        checkEqual(warm.progress.statHits, 2); checkEqual(warm.progress.extracted, 0)
        checkTrue(cold.state.files.allSatisfy { $0.imageContent != nil })
        let restart = FileLibrary(directory: data, embeddingFactory: { ImageTestEmbedding() })
        _ = try await restart.load()
        // Persisted terms keep search independent of both source files and Vision at query time.
        try FileManager.default.removeItem(at: photo)
        checkEqual(restart.searchCatalog.matches("zebra").first?.file.name, photo.lastPathComponent)
        _ = try await restart.synchronizeChanges([photo])
        checkTrue(restart.searchCatalog.matches("zebra").isEmpty)
        let privateImage = root.appendingPathComponent("passport.png")
        try FileManager.default.copyItem(at: screenshot, to: privateImage)
        _ = try await restart.synchronizeChanges([privateImage])
        let current = await restart.current()
        checkNil(current.files.first { $0.name == "passport.png" }?.imageContent)
        checkEqual(current.files.first { $0.name == "passport.png" }?.searchTerms, [])
        let sensitivePixels = root.appendingPathComponent("IMG_0044.png")
        try makeTextImage(sensitivePixels, text: "PASSWORD CREDENTIAL")
        _ = try await restart.synchronizeChanges([sensitivePixels])
        let sensitiveState = await restart.current()
        let sensitiveRecord = sensitiveState.files.first { $0.name == "IMG_0044.png" }
        checkTrue(sensitiveRecord?.sensitive == true)
        checkNil(sensitiveRecord?.imageContent)
        checkEqual(sensitiveRecord?.searchTerms, [])
    }
    private static func makeTextImage(_ url: URL, text: String = "ORBITAL INVOICE 7482") throws {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 1100, height: 300, bitsPerComponent: 8, bytesPerRow: 4400, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw OpenFilesError.message("Could not create OCR fixture") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1100, height: 300))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 62, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 35, y: 130); CTLineDraw(line, context)
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw OpenFilesError.message("Could not write OCR fixture") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw OpenFilesError.message("Could not finish OCR fixture") }
    }
}
