@testable import IndexPhotos
import XCTest

final class ResultIndexBuilderTests: XCTestCase {
    func testIdenticalHashesUseOneNode() {
        var index = PHashBKTree()
        for assetIndex in 0 ..< 10000 {
            index.insert(IndexedFastFeature(assetID: "asset-\(assetIndex)", contentHash: "same", perceptualHash: 0))
        }
        XCTAssertEqual(index.nodeCount, 1)
        XCTAssertTrue(index.query(hash: 0, maximumDistance: 10, limit: 32, excludingContentHash: "same").isEmpty)
    }

    func testExactDuplicatesDoNotConsumeSimilarityLimit() throws {
        var features = (0 ..< 40).map { index in
            IndexedFastFeature(assetID: String(format: "asset-%03d", index), contentHash: "same", perceptualHash: 0)
        }
        features.append(IndexedFastFeature(assetID: "asset-040", contentHash: "edited", perceptualHash: 1))
        features.append(IndexedFastFeature(assetID: "asset-041", contentHash: "same", perceptualHash: 0))
        let result = try ResultIndexBuilder.build(features: features)
        XCTAssertTrue(result.candidates.contains { $0.assetAID == "asset-040" && $0.assetBID == "asset-041" })
    }

    func testNearestMatchesAgreeWithBruteForce() {
        var state: UInt64 = 0x1234_ABCD
        let features = (0 ..< 512).map { index in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let hash = index.isMultiple(of: 3) ? state : state & 0xFFFF
            return IndexedFastFeature(
                assetID: String(format: "asset-%04d", index),
                contentHash: "hash-\(index % 7)", perceptualHash: hash
            )
        }
        var index = PHashBKTree()
        for feature in features {
            index.insert(feature)
        }

        for feature in features.prefix(64) {
            let eligibleFeatures = features.filter { $0.contentHash != feature.contentHash }
            let distances = eligibleFeatures.map {
                PHashMatch(
                    assetID: $0.assetID,
                    contentHash: $0.contentHash,
                    distance: ($0.perceptualHash ^ feature.perceptualHash).nonzeroBitCount
                )
            }
            let nearMatches = distances.filter { $0.distance <= 10 }
            let sortedMatches = nearMatches.sorted {
                $0.distance == $1.distance ? $0.assetID < $1.assetID : $0.distance < $1.distance
            }
            let expected = Array(sortedMatches.prefix(32))
            let actual = index.query(
                hash: feature.perceptualHash,
                maximumDistance: 10,
                limit: 32,
                excludingContentHash: feature.contentHash
            )
            XCTAssertEqual(actual, expected)
        }
    }

    func testInputOrderDoesNotChangeCandidates() throws {
        let features = (0 ..< 80).map { index in
            IndexedFastFeature(
                assetID: String(format: "asset-%03d", index),
                contentHash: "hash-\(index)",
                perceptualHash: UInt64(index)
            )
        }
        let forward = try ResultIndexBuilder.build(features: features)
        let reverse = try ResultIndexBuilder.build(features: features.reversed())
        XCTAssertEqual(forward.candidates.map(\.id), reverse.candidates.map(\.id))
    }

    func testBenchmarkDuplicateHeavyIndex() throws {
        let features = (0 ..< 6000).map { index in
            IndexedFastFeature(
                assetID: String(format: "asset-%06d", index),
                contentHash: "same-bytes",
                perceptualHash: 0
            )
        }
        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = try ResultIndexBuilder.build(features: features)

        print("BENCH duplicate_index count=\(features.count) elapsed=\(startedAt.duration(to: clock.now))")
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups.first?.assetIDs.count, features.count)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testExactDuplicatesAndEditedCandidatesAreSeparated() throws {
        let features = [
            IndexedFastFeature(
                assetID: "asset-a",
                contentHash: "same-bytes",
                perceptualHash: 0
            ),
            IndexedFastFeature(
                assetID: "asset-b",
                contentHash: "same-bytes",
                perceptualHash: 0
            ),
            IndexedFastFeature(
                assetID: "asset-c",
                contentHash: "edited-bytes",
                perceptualHash: 1
            ),
            IndexedFastFeature(
                assetID: "asset-d",
                contentHash: "different-bytes",
                perceptualHash: UInt64.max
            ),
        ]

        let result = try ResultIndexBuilder.build(features: features)

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups.first?.assetIDs, ["asset-a", "asset-b"])
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertTrue(
            result.candidates.allSatisfy { $0.relationKind == "edited_same_photo" }
        )
        XCTAssertTrue(
            result.candidates.allSatisfy {
                [$0.assetAID, $0.assetBID].contains("asset-c")
            }
        )
    }

    func testPHashDistanceThresholdLimitsCandidates() throws {
        let features = [
            IndexedFastFeature(
                assetID: "asset-a",
                contentHash: "hash-a",
                perceptualHash: 0
            ),
            IndexedFastFeature(
                assetID: "asset-b",
                contentHash: "hash-b",
                perceptualHash: (UInt64(1) << 11) - 1
            ),
        ]

        let result = try ResultIndexBuilder.build(features: features)

        XCTAssertTrue(result.candidates.isEmpty)
    }
}
