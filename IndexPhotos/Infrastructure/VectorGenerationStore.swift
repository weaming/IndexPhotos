import CryptoKit
import Foundation

struct VectorGenerationManifest: Codable, Equatable, Sendable {
    let formatVersion: Int
    let generationID: String
    let createdAt: Date
    let algorithmVersion: String
    let modelIdentifier: String
    let metric: String
    let dimension: Int
    let entries: [EmbeddingIndexEntry]
    let indexSHA256: String
}

struct VectorGeneration: Sendable {
    let manifest: VectorGenerationManifest
    let indexData: Data
}

struct VectorGenerationStore: Sendable {
    private static let FORMAT_VERSION = 1
    private static let INDEX_FILE_NAME = "index.bin"
    private static let MANIFEST_FILE_NAME = "manifest.json"
    private static let READY_FILE_NAME = "READY"

    private let paths: CachePaths

    init(cacheRoot: CacheRoot) {
        paths = cacheRoot.paths
    }

    init(paths: CachePaths) {
        self.paths = paths
    }

    func replace(with result: EmbeddingIndexBuildResult) throws {
        guard let indexData = result.indexData,
              let modelIdentifier = result.modelIdentifier,
              let algorithmVersion = result.algorithmVersion,
              let metric = result.metric,
              result.dimension > 0
        else {
            try clearCurrent()
            return
        }

        let generationID = UUID().uuidString.lowercased()
        let generationURL = paths.vectorGenerations
            .appendingPathComponent(generationID, isDirectory: true)

        let manifest = VectorGenerationManifest(
            formatVersion: Self.FORMAT_VERSION,
            generationID: generationID,
            createdAt: .now,
            algorithmVersion: algorithmVersion,
            modelIdentifier: modelIdentifier,
            metric: metric,
            dimension: result.dimension,
            entries: result.entries,
            indexSHA256: HashEncoding.hex(SHA256.hash(data: indexData))
        )
        do {
            try FileManager.default.createDirectory(
                at: generationURL,
                withIntermediateDirectories: false
            )
            try writeAtomically(
                indexData,
                to: generationURL.appendingPathComponent(Self.INDEX_FILE_NAME)
            )
            try writeAtomically(
                encodeManifest(manifest),
                to: generationURL.appendingPathComponent(Self.MANIFEST_FILE_NAME)
            )
            try writeAtomically(
                Data("ready\n".utf8),
                to: generationURL.appendingPathComponent(Self.READY_FILE_NAME)
            )
            try writeAtomically(
                Data("\(generationID)\n".utf8),
                to: paths.vectorCurrent
            )
        } catch {
            let originalError = error
            var cleanupMessage = ""
            do {
                if FileManager.default.fileExists(atPath: generationURL.path) {
                    try FileManager.default.removeItem(at: generationURL)
                }
            } catch {
                cleanupMessage = "；临时目录清理失败：\(error.localizedDescription)"
            }
            throw IndexPhotosError.invalidState(
                "写入向量索引代际失败：\(originalError.localizedDescription)\(cleanupMessage)"
            )
        }
    }

    func loadCurrent() throws -> VectorGeneration? {
        guard FileManager.default.fileExists(atPath: paths.vectorCurrent.path) else {
            return nil
        }

        let currentID = try readCurrentID()
        guard UUID(uuidString: currentID) != nil else {
            throw IndexPhotosError.invalidState("向量索引 CURRENT 无效")
        }
        let generationURL = paths.vectorGenerations
            .appendingPathComponent(currentID, isDirectory: true)
        let generationPath = generationURL.standardizedFileURL.path
        let generationsPath = paths.vectorGenerations.standardizedFileURL.path
        guard generationPath.hasPrefix(generationsPath + "/") else {
            throw IndexPhotosError.invalidState("向量索引代际路径越界")
        }

        let readyURL = generationURL.appendingPathComponent(Self.READY_FILE_NAME)
        guard FileManager.default.fileExists(atPath: readyURL.path) else {
            throw IndexPhotosError.invalidState("向量索引代际未完成")
        }

        let manifestURL = generationURL.appendingPathComponent(Self.MANIFEST_FILE_NAME)
        let indexURL = generationURL.appendingPathComponent(Self.INDEX_FILE_NAME)
        do {
            let manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(
                VectorGenerationManifest.self,
                from: manifestData
            )
            let indexData = try Data(contentsOf: indexURL, options: [.mappedIfSafe])
            guard manifest.generationID == currentID,
                  manifest.formatVersion == Self.FORMAT_VERSION,
                  manifest.indexSHA256 == HashEncoding.hex(
                      SHA256.hash(data: indexData)
                  )
            else {
                throw IndexPhotosError.invalidState("向量索引代际校验失败")
            }
            _ = try RustHnswIndex(serializedData: indexData)
            return VectorGeneration(manifest: manifest, indexData: indexData)
        } catch let error as IndexPhotosError {
            throw error
        } catch {
            throw IndexPhotosError.invalidState(
                "读取向量索引代际失败：\(error.localizedDescription)"
            )
        }
    }

    func clearCurrent() throws {
        guard FileManager.default.fileExists(atPath: paths.vectorCurrent.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: paths.vectorCurrent)
        } catch {
            throw IndexPhotosError.invalidState(
                "清理当前向量索引失败：\(error.localizedDescription)"
            )
        }
    }

    func removeSupersededGenerations(keeping limit: Int = 2) throws -> Int {
        let keepCount = max(limit, 0)
        let currentID: String?
        if FileManager.default.fileExists(atPath: paths.vectorCurrent.path) {
            currentID = try readCurrentID()
        } else {
            currentID = nil
        }
        let generationURLs = try FileManager.default.contentsOfDirectory(
            at: paths.vectorGenerations,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let sortedURLs = generationURLs
            .filter {
                guard UUID(uuidString: $0.lastPathComponent) != nil else {
                    return false
                }
                return (try? $0.resourceValues(
                    forKeys: [.isDirectoryKey]
                ).isDirectory) == true
            }
            .sorted {
                let leftDate = (try? $0.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                let rightDate = (try? $1.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }

        var removedCount = 0
        var retainedCount = 0
        for generationURL in sortedURLs {
            let generationID = generationURL.lastPathComponent
            if generationID == currentID || retainedCount < keepCount {
                retainedCount += generationID == currentID ? 0 : 1
                continue
            }
            do {
                try FileManager.default.removeItem(at: generationURL)
                removedCount += 1
            } catch {
                throw IndexPhotosError.invalidState(
                    "删除旧向量索引代际失败：\(generationID)（\(error.localizedDescription)）"
                )
            }
        }
        return removedCount
    }

    private func readCurrentID() throws -> String {
        do {
            let data = try Data(contentsOf: paths.vectorCurrent, options: [.mappedIfSafe])
            let value = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw IndexPhotosError.invalidState("向量索引 CURRENT 为空")
            }
            return value
        } catch let error as IndexPhotosError {
            throw error
        } catch {
            throw IndexPhotosError.invalidState(
                "读取向量索引 CURRENT 失败：\(error.localizedDescription)"
            )
        }
    }

    private func encodeManifest(_ manifest: VectorGenerationManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }
}
