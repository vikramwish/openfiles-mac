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
        ("Visual subject search, OCR, cache, persistence, and read-only image analysis", imageSearch),
        ("Photo GPS and embedded place search stays local, cached, and read-only", photoLocationSearch)
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
if cold.state.files.contains(where: { $0.imageContent == nil }) {
            print("Image extraction diagnostics: " + cold.state.files.map { $0.name + ": " + ($0.indexMetadata?.detail ?? "no metadata") }.joined(separator: "; "))
        }
        let visionRecords = cold.state.files.compactMap(\.imageContent)
        let canFindZebra = visionRecords.contains { $0.subjects.contains { $0.name.localizedCaseInsensitiveContains("zebra") } }
        let canReadText = visionRecords.contains { $0.textTerms.contains("orbital") }
        if canFindZebra {
            let images = library.searchCatalog.matches("images of a zebra")
            checkEqual(images.count, 1); checkEqual(images.first?.file.name, photo.lastPathComponent)
            checkEqual(images.first?.reason, "Image subject match")
            checkTrue(images.first?.file.imageContent?.subjects.contains { $0.name.lowercased().contains("zebra") && $0.confidence >= 0.25 } == true)
            checkEqual(library.searchCatalog.matches("pictures of zebras").first?.file.name, photo.lastPathComponent)
        } else { print("SKIP Vision model did not classify the fixture as a zebra") }
        if canReadText { checkEqual(library.searchCatalog.matches("orbital").first?.file.name, screenshot.lastPathComponent) }
        else { print("SKIP Vision OCR model unavailable") }
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
        if canFindZebra { checkEqual(restart.searchCatalog.matches("zebra").first?.file.name, photo.lastPathComponent) }
        _ = try await restart.synchronizeChanges([photo])
        if canFindZebra { checkTrue(restart.searchCatalog.matches("zebra").isEmpty) }
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
        if canReadText {
            checkTrue(sensitiveRecord?.sensitive == true)
            checkNil(sensitiveRecord?.imageContent)
            checkEqual(sensitiveRecord?.searchTerms, [])
        } else { print("SKIP OCR sensitivity check because Vision text recognition is unavailable") }
    }
    static func photoLocationSearch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFilesLocations-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Pictures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let fixture = Bundle.module.url(forResource: "sample-animal", withExtension: "jpg", subdirectory: "Fixtures"),
              let source = CGImageSourceCreateWithURL(fixture as CFURL, nil) else { throw OpenFilesError.message("Missing location fixture") }
        func writePhoto(_ name: String, latitude: Double, longitude: Double, city: String?) throws -> URL {
            let url = root.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw OpenFilesError.message("Could not create location fixture") }
            var properties: [String: Any] = [kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: abs(latitude), kCGImagePropertyGPSLatitudeRef as String: latitude < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude as String: abs(longitude), kCGImagePropertyGPSLongitudeRef as String: longitude < 0 ? "W" : "E"]]
            if let city { properties[kCGImagePropertyIPTCDictionary as String] = [kCGImagePropertyIPTCCity as String: city, kCGImagePropertyIPTCCountryPrimaryLocationName as String: "Australia"] }
            CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw OpenFilesError.message("Could not finish location fixture") }
            return url
        }
        let sydney = try writePhoto("IMG_1001.jpg", latitude: -33.86, longitude: 151.21, city: nil)
        _ = try writePhoto("IMG_1002.jpg", latitude: -37.81, longitude: 144.96, city: "Fitzroy")
        let invalid = try writePhoto("IMG_1003.jpg", latitude: 200, longitude: 151, city: nil)
        let bytes = try Data(contentsOf: sydney), stamp = try FileStamp.read(sydney)
        let library = FileLibrary(directory: base.appendingPathComponent("Data"), embeddingFactory: { ImageTestEmbedding() })
        _ = try await library.load(); try await library.addRoot(root)
        _ = try await library.scan()
        checkEqual(library.searchCatalog.matches("photos taken in Sydney").map { $0.file.name }, ["IMG_1001.jpg"])
        checkEqual(library.searchCatalog.matches("images in Melbourne").map { $0.file.name }, ["IMG_1002.jpg"])
        checkEqual(library.searchCatalog.matches("photos from last month taken in Fitzroy").count, 0)
        checkEqual(library.searchCatalog.matches("photos taken in Fitzroy").map { $0.file.name }, ["IMG_1002.jpg"])
        checkEqual(library.searchCatalog.matches("photos in Australia").map { $0.file.name }, ["IMG_1002.jpg"])
        checkTrue(library.searchCatalog.matches("photos in Atlantis").isEmpty)
        if currentZebraAvailable(library.searchCatalog.matches("images of a zebra")) {
            checkEqual(library.searchCatalog.matches("zebra photos near Sydney").first?.file.name, "IMG_1001.jpg")
        }
        checkEqual(library.searchCatalog.matches("photos taken in Sydney").first?.reason, "Photo location metadata")
        let current = await library.current()
        checkNil(current.files.first { $0.name == invalid.lastPathComponent }?.imageContent?.location)
        checkTrue(abs((current.files.first { $0.name == sydney.lastPathComponent }?.imageContent?.location?.latitude ?? 0) + 33.86) < 0.00001)
        checkEqual(try Data(contentsOf: sydney), bytes); checkEqual(try FileStamp.read(sydney), stamp)
        let warm = try await library.scan(); checkEqual(warm.progress.statHits, 3)
        let restart = FileLibrary(directory: base.appendingPathComponent("Data"), embeddingFactory: { ImageTestEmbedding() })
        _ = try await restart.load()
        try FileManager.default.removeItem(at: sydney)
        checkEqual(restart.searchCatalog.matches("photos taken in Sydney").first?.file.name, "IMG_1001.jpg")
        _ = try await restart.synchronizeChanges([sydney])
        checkTrue(restart.searchCatalog.matches("photos taken in Sydney").isEmpty)
        let privatePhoto = root.appendingPathComponent("passport.jpg")
        try bytes.write(to: privatePhoto)
        _ = try await restart.synchronizeChanges([privatePhoto])
        let protectedState = await restart.current()
        checkNil(protectedState.files.first { $0.name == privatePhoto.lastPathComponent }?.imageContent)
        checkTrue(restart.searchCatalog.matches("photos taken in Sydney").isEmpty)
        // Folder constraints retain their existing interpretation.
        let folderPlan = NavigationQuery("photos in Pictures")
        checkEqual(folderPlan.location, "pictures"); checkNil(folderPlan.photoLocation)
    }
    private static func currentZebraAvailable(_ matches: [FileSearchMatch]) -> Bool {
        matches.contains { $0.file.imageContent?.subjects.contains { $0.name.localizedCaseInsensitiveContains("zebra") } == true }
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
