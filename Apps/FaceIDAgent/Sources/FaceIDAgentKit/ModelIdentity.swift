import CryptoKit
import FaceIDCore
import Foundation

/// Content hash of a model file or bundle. Stored in templates so swapping the model
/// invalidates old embeddings instead of silently comparing incompatible vectors.
public enum ModelIdentity {
    public static func compute(for url: URL) throws -> String {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw FaceIDError.modelLoadFailed
        }

        var hasher = SHA256()
        if isDirectory.boolValue {
            guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
                throw FaceIDError.modelLoadFailed
            }
            let base = url.standardizedFileURL.path
            var files: [(relative: String, url: URL)] = []
            for case let file as URL in enumerator {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                files.append((String(file.standardizedFileURL.path.dropFirst(base.count)), file))
            }
            for file in files.sorted(by: { $0.relative < $1.relative }) {
                hasher.update(data: Data(file.relative.utf8))
                hasher.update(data: try read(file.url))
            }
        } else {
            hasher.update(data: try read(url))
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "sha256:" + hex.prefix(32)
    }

    private static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw FaceIDError.modelLoadFailed
        }
    }
}
