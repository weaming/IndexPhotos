@testable import IndexPhotos
import XCTest

final class GeometryVerifierTests: XCTestCase {
    func testMissingThumbnailsProduceUnavailableEvidence() throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosGeometryTests-\(UUID().uuidString)")
        let verifier = GeometryVerifier(
            thumbnailStore: ThumbnailStore(storageDirectory: storageURL)
        )
        let candidate = SimilarityReviewItem(
            id: "candidate-1",
            assetAID: "asset-a",
            assetAPath: "/tmp/a.jpg",
            assetASizeBytes: 1_000_000,
            assetASourceFingerprint: "source-a",
            thumbnailARelativePath: nil,
            assetBID: "asset-b",
            assetBPath: "/tmp/b.jpg",
            assetBSizeBytes: 2_000_000,
            assetBSourceFingerprint: "source-b",
            thumbnailBRelativePath: nil,
            relationKind: "edited_same_photo",
            score: 0.9,
            evidenceJSON: #"{"distance":0.1}"#,
            algorithmVersion: "test-v1",
            decision: nil
        )

        let records = try verifier.annotate(candidates: [candidate])

        let record = try XCTUnwrap(records.first)
        let evidence = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(record.evidenceJSON.utf8))
                as? [String: Any]
        )
        let geometry = try XCTUnwrap(evidence["geometry"] as? [String: Any])
        XCTAssertEqual(
            geometry["algorithm"] as? String,
            GeometryVerifier.ALGORITHM_VERSION
        )
        XCTAssertEqual(geometry["status"] as? String, "thumbnail_unavailable")
    }

    func testCurrentGeometryEvidenceIsNotRecomputed() throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosGeometryTests-\(UUID().uuidString)")
        let verifier = GeometryVerifier(
            thumbnailStore: ThumbnailStore(storageDirectory: storageURL)
        )
        let evidenceJSON = """
        {
          "geometry": {
            "algorithm": "\(GeometryVerifier.ALGORITHM_VERSION)",
            "status": "completed",
            "assetASourceFingerprint": "source-a",
            "assetBSourceFingerprint": "source-b"
          }
        }
        """
        let candidate = SimilarityReviewItem(
            id: "candidate-2",
            assetAID: "asset-a",
            assetAPath: "/tmp/a.jpg",
            assetASizeBytes: 1_000_000,
            assetASourceFingerprint: "source-a",
            thumbnailARelativePath: nil,
            assetBID: "asset-b",
            assetBPath: "/tmp/b.jpg",
            assetBSizeBytes: 2_000_000,
            assetBSourceFingerprint: "source-b",
            thumbnailBRelativePath: nil,
            relationKind: "edited_same_photo",
            score: 0.9,
            evidenceJSON: evidenceJSON,
            algorithmVersion: "test-v1",
            decision: nil
        )

        XCTAssertTrue(try verifier.annotate(candidates: [candidate]).isEmpty)
    }
}
