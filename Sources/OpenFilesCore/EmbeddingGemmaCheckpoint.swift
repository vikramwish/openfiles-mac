import Foundation
import CryptoKit

/// Identifies the actual local weights and tokenizer, including quantized variants.
/// A changed checkpoint must never reuse vectors from the previous embedding space.
public struct EmbeddingGemmaCheckpoint: Sendable {
    public let directory: URL
    public let identifier: String

    public static func inspect(directory: URL) throws -> EmbeddingGemmaCheckpoint {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        let configURL = directory.appendingPathComponent("config.json")
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        guard let type = config?["model_type"] as? String,
              ["embedding_gemma2", "embedding_gemma2_text"].contains(type) else {
            throw OpenFilesError.message("Choose an EmbeddingGemma 2 checkpoint folder containing config.json, tokenizer files, and safetensors weights.")
        }
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            guard fm.isReadableFile(atPath: directory.appendingPathComponent(name).path) else {
                throw OpenFilesError.message("The model folder is missing \(name). Download the complete checkpoint first.")
            }
        }
        var files: [URL] = []
        // Only model inputs affect identity; Hugging Face download metadata does not.
        func collect(_ folder: URL) throws {
            for url in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    // Checkpoint metadata can be nested (e.g. 1_Pooling/config.json).
                    // Do not follow directory symlinks or recurse outside the selected folder.
                    if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true { try collect(url) }
                } else if ["json", "safetensors", "model", "txt"].contains(url.pathExtension) {
                    files.append(url)
                }
            }
        }
        try collect(directory)
        guard files.contains(where: { $0.pathExtension == "safetensors" }) else {
            throw OpenFilesError.message("No safetensors weights were found in the model folder.")
        }
        var digest = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let name = String(file.path.dropFirst(directory.path.count + 1))
            digest.update(data: Data((name + "\0").utf8))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var fileDigest = SHA256()
            while let block = try handle.read(upToCount: 2 * 1024 * 1024), !block.isEmpty {
                try Task.checkCancellation()
                fileDigest.update(data: block)
            }
            digest.update(data: Data(fileDigest.finalize()))
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return EmbeddingGemmaCheckpoint(directory: directory,
            identifier: "embeddinggemma-2-\(EmbeddingGemmaInput.runtimeVersion)-\(EmbeddingGemmaInput.preparationVersion)-d768-\(hash)")
    }
}
