import Foundation

enum RustCoreError: LocalizedError {
    case hasherUnavailable
    case hashingFailed
    case perceptualHashFailed
    case geometryVerificationFailed
    case invalidGeometryResult
    case hnswIndexUnavailable
    case hnswOperationFailed

    var errorDescription: String? {
        switch self {
        case .hasherUnavailable:
            return "无法创建 Rust BLAKE3 计算器。"
        case .hashingFailed:
            return "BLAKE3 计算失败。"
        case .perceptualHashFailed:
            return "pHash 计算失败。"
        case .geometryVerificationFailed:
            return "几何一致性复核失败。"
        case .invalidGeometryResult:
            return "几何复核返回了无效数值。"
        case .hnswIndexUnavailable:
            return "无法创建向量近邻索引。"
        case .hnswOperationFailed:
            return "向量近邻索引操作失败。"
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

    static func verifyGeometry(
        left: GeometryImage,
        right: GeometryImage
    ) throws -> RustGeometryResult {
        var rawResult = IndexPhotosGeometryResult(
            matched_count: 0,
            inlier_count: 0,
            inlier_ratio: 0,
            coverage: 0,
            median_error: 0,
            passed: 0
        )
        let succeeded = left.data.withUnsafeBytes { leftBuffer in
            right.data.withUnsafeBytes { rightBuffer in
                index_photos_verify_geometry(
                    leftBuffer.bindMemory(to: UInt8.self).baseAddress,
                    left.width,
                    left.height,
                    left.bytesPerRow,
                    rightBuffer.bindMemory(to: UInt8.self).baseAddress,
                    right.width,
                    right.height,
                    right.bytesPerRow,
                    &rawResult
                )
            }
        }
        guard succeeded else {
            throw RustCoreError.geometryVerificationFailed
        }
        guard rawResult.inlier_ratio.isFinite,
              rawResult.coverage.isFinite,
              rawResult.median_error.isFinite
        else {
            throw RustCoreError.invalidGeometryResult
        }
        return RustGeometryResult(
            matchedCount: rawResult.matched_count,
            inlierCount: rawResult.inlier_count,
            inlierRatio: rawResult.inlier_ratio,
            coverage: rawResult.coverage,
            medianError: rawResult.median_error,
            passed: rawResult.passed != 0
        )
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

struct RustGeometryResult: Sendable {
    let matchedCount: UInt32
    let inlierCount: UInt32
    let inlierRatio: Float
    let coverage: Float
    let medianError: Float
    let passed: Bool

    init(
        matchedCount: UInt32,
        inlierCount: UInt32,
        inlierRatio: Float,
        coverage: Float,
        medianError: Float,
        passed: Bool
    ) {
        self.matchedCount = matchedCount
        self.inlierCount = inlierCount
        self.inlierRatio = inlierRatio
        self.coverage = coverage
        self.medianError = medianError
        self.passed = passed
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

struct RustHnswMatch: Sendable {
    let label: UInt64
    let distance: Float
}

final class RustHnswIndex {
    private var handle: OpaquePointer?

    init(
        dimension: Int,
        maxNeighbors: Int = 16,
        constructionEf: Int = 64
    ) throws {
        guard dimension > 0,
              maxNeighbors >= 2,
              constructionEf > 0,
              let handle = index_photos_hnsw_create(
                  dimension,
                  maxNeighbors,
                  constructionEf
              )
        else {
            throw RustCoreError.hnswIndexUnavailable
        }
        self.handle = handle
    }

    func insert(label: UInt64, vector: [Float]) throws {
        guard let handle else {
            throw RustCoreError.hnswOperationFailed
        }
        let succeeded = vector.withUnsafeBufferPointer { buffer in
            index_photos_hnsw_insert(
                handle,
                label,
                buffer.baseAddress,
                buffer.count
            )
        }
        guard succeeded else {
            throw RustCoreError.hnswOperationFailed
        }
    }

    func search(
        vector: [Float],
        limit: Int,
        searchEf: Int = 64
    ) throws -> [RustHnswMatch] {
        guard let handle, limit > 0, searchEf > 0 else {
            throw RustCoreError.hnswOperationFailed
        }

        var labels = [UInt64](repeating: 0, count: limit)
        var distances = [Float](repeating: 0, count: limit)
        let count = vector.withUnsafeBufferPointer { vectorBuffer in
            labels.withUnsafeMutableBufferPointer { labelBuffer in
                distances.withUnsafeMutableBufferPointer { distanceBuffer in
                    index_photos_hnsw_search(
                        handle,
                        vectorBuffer.baseAddress,
                        vectorBuffer.count,
                        limit,
                        searchEf,
                        labelBuffer.baseAddress,
                        distanceBuffer.baseAddress,
                        limit
                    )
                }
            }
        }
        guard count <= limit else {
            throw RustCoreError.hnswOperationFailed
        }
        return (0 ..< count).map { index in
            RustHnswMatch(label: labels[index], distance: distances[index])
        }
    }

    convenience init(serializedData: Data) throws {
        let handle = serializedData.withUnsafeBytes { buffer in
            index_photos_hnsw_deserialize(
                buffer.bindMemory(to: UInt8.self).baseAddress,
                buffer.count
            )
        }
        guard let handle else {
            throw RustCoreError.hnswIndexUnavailable
        }
        self.init(handle: handle)
    }

    func serializedData() throws -> Data {
        guard let handle else {
            throw RustCoreError.hnswOperationFailed
        }
        let length = index_photos_hnsw_serialized_length(handle)
        guard length > 0 else {
            throw RustCoreError.hnswOperationFailed
        }

        var data = Data(count: length)
        let succeeded = data.withUnsafeMutableBytes { buffer in
            index_photos_hnsw_serialize(
                handle,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                buffer.count
            )
        }
        guard succeeded else {
            throw RustCoreError.hnswOperationFailed
        }
        return data
    }

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        if let handle {
            index_photos_hnsw_destroy(handle)
        }
    }
}
