import CryptoKit
import Foundation

struct CachePaths: Sendable {
    let root: URL
    let manifest: URL
    let database: URL
    let vectors: URL
    let vectorGenerations: URL
    let thumbnails: URL
    let smallThumbnails: URL
    let mediumThumbnails: URL
    let work: URL
    let scans: URL
    let logs: URL
    let locks: URL
    let lock: URL

    init(root: URL) {
        self.root = root
        manifest = root.appendingPathComponent("manifest.json")
        database = root.appendingPathComponent("catalog.sqlite")
        vectors = root.appendingPathComponent("vectors", isDirectory: true)
        vectorGenerations = root.appendingPathComponent("vectors/generations", isDirectory: true)
        thumbnails = root.appendingPathComponent("thumbnails", isDirectory: true)
        smallThumbnails = root.appendingPathComponent("thumbnails/small", isDirectory: true)
        mediumThumbnails = root.appendingPathComponent("thumbnails/medium", isDirectory: true)
        work = root.appendingPathComponent("work", isDirectory: true)
        scans = root.appendingPathComponent("work/scans", isDirectory: true)
        logs = root.appendingPathComponent("logs", isDirectory: true)
        locks = root.appendingPathComponent("locks", isDirectory: true)
        lock = root.appendingPathComponent("locks/index.lock")
    }
}

struct CacheManifest: Codable, Sendable {
    let schemaVersion: Int
    let cacheVersion: Int
    let featureVersion: Int
    let createdAt: Date
    var updatedAt: Date
}

struct CacheRoot: Sendable {
    let paths: CachePaths

    init(fileManager: FileManager = .default) throws {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".index-photos", isDirectory: true)

        paths = CachePaths(root: root)
    }

    func prepare() throws {
        let directories = [
            paths.root,
            paths.vectors,
            paths.vectorGenerations,
            paths.thumbnails,
            paths.smallThumbnails,
            paths.mediumThumbnails,
            paths.work,
            paths.scans,
            paths.logs,
            paths.locks,
        ]

        do {
            for directory in directories {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }

            try writeManifest()
        } catch {
            throw IndexPhotosError.cacheDirectoryUnavailable(paths.root, error)
        }
    }

    private func writeManifest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let manifest = if let data = try? Data(contentsOf: paths.manifest),
                          let existingManifest = try? JSONDecoder.cacheDecoder.decode(CacheManifest.self, from: data)
        {
            CacheManifest(
                schemaVersion: existingManifest.schemaVersion,
                cacheVersion: existingManifest.cacheVersion,
                featureVersion: existingManifest.featureVersion,
                createdAt: existingManifest.createdAt,
                updatedAt: .now
            )
        } else {
            CacheManifest(
                schemaVersion: 1,
                cacheVersion: 1,
                featureVersion: 1,
                createdAt: .now,
                updatedAt: .now
            )
        }

        let data = try encoder.encode(manifest)
        try data.write(to: paths.manifest, options: .atomic)
    }
}

enum StableIdentifier {
    static func rootID(for url: URL) -> UUID {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = Array(SHA256.hash(data: Data(path.utf8)).prefix(16))
        var bytes = digest
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum HashEncoding {
    private static let HEX_DIGITS = Array("0123456789abcdef".utf8)

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        var encoded: [UInt8] = []
        encoded.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            encoded.append(HEX_DIGITS[Int(byte >> 4)])
            encoded.append(HEX_DIGITS[Int(byte & 0x0F)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}

private extension JSONDecoder {
    static var cacheDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
