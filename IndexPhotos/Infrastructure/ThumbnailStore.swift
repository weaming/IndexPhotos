import CryptoKit
import Foundation

struct ThumbnailStore: Sendable {
    private let paths: CachePaths
    var storageURL: URL {
        paths.root
    }

    init(cacheRoot: CacheRoot) {
        paths = cacheRoot.paths
    }

    init(storageDirectory: URL) {
        paths = CachePaths(root: storageDirectory)
    }

    func store(
        assetID: String,
        sourceFingerprint: String,
        data: Data
    ) throws -> ThumbnailObject {
        let objectKey = makeObjectKey(
            assetID: assetID,
            sourceFingerprint: sourceFingerprint
        )
        let relativePath = "thumbnails/small/\(objectKey).jpg"
        let destination = paths.root.appendingPathComponent(relativePath)

        try FileManager.default.createDirectory(
            at: paths.work,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            return ThumbnailObject(key: objectKey, relativePath: relativePath)
        }

        let temporaryURL = paths.work.appendingPathComponent(
            "thumbnail-\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporaryURL)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch CocoaError.fileWriteFileExists {
            try FileManager.default.removeItem(at: temporaryURL)
        } catch {
            let storageError = error
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try FileManager.default.removeItem(at: temporaryURL)
            }
            throw storageError
        }

        return ThumbnailObject(key: objectKey, relativePath: relativePath)
    }

    func remove(relativePath: String) throws {
        let rootPath = paths.root.standardizedFileURL.path
        let fileURL = paths.root.appendingPathComponent(relativePath)
            .standardizedFileURL
        let filePath = fileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw IndexPhotosError.invalidState("缓存对象路径越界：\(relativePath)")
        }
        guard FileManager.default.fileExists(atPath: filePath) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    func contains(relativePath: String) -> Bool {
        let rootPath = paths.root.standardizedFileURL.path
        let fileURL = paths.root.appendingPathComponent(relativePath)
            .standardizedFileURL
        guard fileURL.path.hasPrefix(rootPath + "/") else {
            return false
        }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    func load(relativePath: String) throws -> Data {
        let rootPath = paths.root.standardizedFileURL.path
        let fileURL = paths.root.appendingPathComponent(relativePath)
            .standardizedFileURL
        guard fileURL.path.hasPrefix(rootPath + "/") else {
            throw IndexPhotosError.invalidState("缓存对象路径越界：\(relativePath)")
        }
        do {
            return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw IndexPhotosError.invalidState(
                "无法读取缓存缩略图：\(relativePath)（\(error.localizedDescription)）"
            )
        }
    }

    private func makeObjectKey(
        assetID: String,
        sourceFingerprint: String
    ) -> String {
        let seed = "small-v1:\(assetID):\(sourceFingerprint)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return HashEncoding.hex(digest)
    }
}
