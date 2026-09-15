import Foundation
import XCTest

@testable import IndexPhotos

final class ImageEmbeddingTests: XCTestCase {
    func testVisionFeaturePrintProducesNormalizedEmbedding() async throws {
        let imageData = try XCTUnwrap(
            Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )
        )
        let provider = VisionFeaturePrintProvider()

        let embedding = try await provider.makeEmbedding(thumbnailData: imageData)

        XCTAssertEqual(embedding.algorithmVersion, VisionFeaturePrintProvider.ALGORITHM_VERSION)
        XCTAssertGreaterThan(embedding.dimension, 0)
        XCTAssertTrue(embedding.values.allSatisfy(\.isFinite))

        let squaredMagnitude = embedding.values.reduce(into: Double.zero) { result, value in
            result += Double(value) * Double(value)
        }
        XCTAssertEqual(squaredMagnitude, 1, accuracy: 0.0001)
    }
}
