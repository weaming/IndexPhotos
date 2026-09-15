import Foundation
import Vision

struct ImageEmbedding: Codable, Equatable, Sendable {
    let modelIdentifier: String
    let algorithmVersion: String
    let metric: String
    let values: [Float]

    var dimension: Int {
        values.count
    }
}

struct EmbeddingFeatureRecord: Codable, Equatable, Sendable {
    let sourceFingerprint: String
    let modelIdentifier: String
    let algorithmVersion: String
    let metric: String
    let values: [Float]

    init(sourceFingerprint: String, embedding: ImageEmbedding) {
        self.sourceFingerprint = sourceFingerprint
        modelIdentifier = embedding.modelIdentifier
        algorithmVersion = embedding.algorithmVersion
        metric = embedding.metric
        values = embedding.values
    }

    var embedding: ImageEmbedding {
        ImageEmbedding(
            modelIdentifier: modelIdentifier,
            algorithmVersion: algorithmVersion,
            metric: metric,
            values: values
        )
    }
}

protocol ImageEmbeddingProvider: Sendable {
    var algorithmVersion: String { get }

    func makeEmbedding(thumbnailData: Data) async throws -> ImageEmbedding
}

struct VisionFeaturePrintProvider: ImageEmbeddingProvider {
    static let ALGORITHM_VERSION = "vision-feature-print-v2-scale-to-fit"
    private static let MODEL_IDENTIFIER = "apple-vision-feature-print-revision-2"
    private static let METRIC = "cosine"

    let algorithmVersion = Self.ALGORITHM_VERSION

    func makeEmbedding(thumbnailData: Data) async throws -> ImageEmbedding {
        try Task.checkCancellation()

        var request = GenerateImageFeaturePrintRequest(.revision2)
        request.cropAndScaleAction = .scaleToFit
        let observation = try await request.perform(on: thumbnailData)
        let values = try normalizedValues(from: observation)

        return ImageEmbedding(
            modelIdentifier: Self.MODEL_IDENTIFIER,
            algorithmVersion: Self.ALGORITHM_VERSION,
            metric: Self.METRIC,
            values: values
        )
    }

    private func normalizedValues(
        from observation: FeaturePrintObservation
    ) throws -> [Float] {
        guard observation.elementCount > 0 else {
            throw ImageEmbeddingError.emptyFeaturePrint
        }

        let values: [Float]
        switch observation.elementType {
        case .float:
            values = try readFloatValues(
                from: observation.data,
                count: observation.elementCount
            )
        case .double:
            values = try readDoubleValues(
                from: observation.data,
                count: observation.elementCount
            )
        @unknown default:
            throw ImageEmbeddingError.unsupportedElementType
        }

        guard values.allSatisfy(\.isFinite) else {
            throw ImageEmbeddingError.invalidFeaturePrint
        }

        let squaredMagnitude = values.reduce(into: Double.zero) { result, value in
            result += Double(value) * Double(value)
        }
        guard squaredMagnitude.isFinite, squaredMagnitude > 0 else {
            throw ImageEmbeddingError.invalidFeaturePrint
        }

        let magnitude = sqrt(squaredMagnitude)
        return values.map { Float(Double($0) / magnitude) }
    }

    private func readFloatValues(from data: Data, count: Int) throws -> [Float] {
        let expectedByteCount = count * MemoryLayout<Float>.size
        guard data.count == expectedByteCount else {
            throw ImageEmbeddingError.invalidFeaturePrint
        }

        return data.withUnsafeBytes { buffer in
            (0 ..< count).map { index in
                buffer.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Float>.size,
                    as: Float.self
                )
            }
        }
    }

    private func readDoubleValues(from data: Data, count: Int) throws -> [Float] {
        let expectedByteCount = count * MemoryLayout<Double>.size
        guard data.count == expectedByteCount else {
            throw ImageEmbeddingError.invalidFeaturePrint
        }

        return data.withUnsafeBytes { buffer in
            (0 ..< count).map { index in
                let value = buffer.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Double>.size,
                    as: Double.self
                )
                return Float(value)
            }
        }
    }
}

enum ImageEmbeddingError: LocalizedError {
    case emptyFeaturePrint
    case unsupportedElementType
    case invalidFeaturePrint

    var errorDescription: String? {
        switch self {
        case .emptyFeaturePrint:
            "Vision 返回了空的图片特征。"
        case .unsupportedElementType:
            "Vision 返回了不支持的图片特征类型。"
        case .invalidFeaturePrint:
            "Vision 图片特征包含无效数值。"
        }
    }
}
