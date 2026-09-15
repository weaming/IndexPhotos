import Foundation

enum RustCoreError: LocalizedError {
    case hasherUnavailable
    case hashingFailed
    case perceptualHashFailed

    var errorDescription: String? {
        switch self {
        case .hasherUnavailable:
            return "无法创建 Rust BLAKE3 计算器。"
        case .hashingFailed:
            return "BLAKE3 计算失败。"
        case .perceptualHashFailed:
            return "pHash 计算失败。"
        }
    }
}

enum RustCore {
    private static let HASH_LENGTH = 32

    static func blake3Hex(_ data: Data) throws -> String {
        let hasher = try RustBlake3Hasher()
        try hasher.update(data)
        return try hasher.finalize()
    }

    static func perceptualHash(
        rgbaData: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws -> UInt64 {
        var result: UInt64 = 0
        let succeeded = rgbaData.withUnsafeBytes { buffer in
            index_photos_perceptual_hash(
                buffer.bindMemory(to: UInt8.self).baseAddress,
                width,
                height,
                bytesPerRow,
                &result
            )
        }
        guard succeeded else {
            throw RustCoreError.perceptualHashFailed
        }
        return result
    }

    fileprivate static func finalize(_ hasher: OpaquePointer) throws -> String {
        var bytes = [UInt8](repeating: 0, count: HASH_LENGTH)
        let succeeded = bytes.withUnsafeMutableBufferPointer { buffer in
            index_photos_blake3_finalize(
                hasher,
                buffer.baseAddress,
                buffer.count
            )
        }
        guard succeeded else {
            throw RustCoreError.hashingFailed
        }

        return HashEncoding.hex(bytes)
    }
}

final class RustBlake3Hasher {
    private var handle: OpaquePointer?

    init() throws {
        guard let handle = index_photos_blake3_create() else {
            throw RustCoreError.hasherUnavailable
        }
        self.handle = handle
    }

    func update(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            try update(buffer)
        }
    }

    func update(_ buffer: UnsafeRawBufferPointer) throws {
        guard let handle else {
            throw RustCoreError.hashingFailed
        }

        let succeeded = index_photos_blake3_update(
            handle,
            buffer.bindMemory(to: UInt8.self).baseAddress,
            buffer.count
        )
        guard succeeded else {
            throw RustCoreError.hashingFailed
        }
    }

    func finalize() throws -> String {
        guard let handle else {
            throw RustCoreError.hashingFailed
        }
        defer {
            index_photos_blake3_destroy(handle)
            self.handle = nil
        }
        return try RustCore.finalize(handle)
    }

    deinit {
        if let handle {
            index_photos_blake3_destroy(handle)
        }
    }
}
