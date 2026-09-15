@testable import IndexPhotos
import XCTest

final class EmbeddingIndexBuilderTests: XCTestCase {
    func testEditedCandidateIsReturnedAndKnownExactDuplicateIsExcluded() throws {
        let embeddingA = ImageEmbedding(
            modelIdentifier: "test-model",
            algorithmVersion: "test-v1",
            metric: "cosine",
            values: [1, 0]
        )
        let embeddingB = ImageEmbedding(
            modelIdentifier: "test-model",
            algorithmVersion: "test-v1",
            metric: "cosine",
            values: [0.995, 0.1]
        )
        let embeddings = [
            IndexedEmbedding(
                assetID: "asset-a",
                sourceFingerprint: "source-a",
                contentHash: "bytes-a",
                embedding: embeddingA
            ),
            IndexedEmbedding(
                assetID: "asset-b",
                sourceFingerprint: "source-b",
                contentHash: "bytes-b",
                embedding: embeddingB
            ),
            IndexedEmbedding(
                assetID: "asset-c",
                sourceFingerprint: "source-c",
                contentHash: "bytes-a",
                embedding: embeddingA
            ),
            IndexedEmbedding(
                assetID: "asset-d",
                sourceFingerprint: "source-d",
                contentHash: "bytes-d",
                embedding: ImageEmbedding(
                    modelIdentifier: "test-model",
                    algorithmVersion: "test-v1",
                    metric: "cosine",
                    values: [-1, 0]
                )
            ),
        ]

        let candidates = try EmbeddingIndexBuilder.build(embeddings: embeddings)

        XCTAssertTrue(
            candidates.contains {
                $0.assetAID == "asset-a" && $0.assetBID == "asset-b"
            }
        )
        XCTAssertFalse(
            candidates.contains {
                Set([$0.assetAID, $0.assetBID]) == Set(["asset-a", "asset-c"])
            }
        )
        XCTAssertFalse(
            candidates.contains {
                Set([$0.assetAID, $0.assetBID]) == Set(["asset-a", "asset-d"])
            }
        )
    }

    func testDifferentEmbeddingModelsAreNotMixed() throws {
        let embeddings = [
            IndexedEmbedding(
                assetID: "asset-a",
                sourceFingerprint: "source-a",
                contentHash: "bytes-a",
                embedding: ImageEmbedding(
                    modelIdentifier: "model-a",
                    algorithmVersion: "v1",
                    metric: "cosine",
                    values: [1, 0]
                )
            ),
            IndexedEmbedding(
                assetID: "asset-b",
                sourceFingerprint: "source-b",
                contentHash: "bytes-b",
                embedding: ImageEmbedding(
                    modelIdentifier: "model-b",
                    algorithmVersion: "v1",
                    metric: "cosine",
                    values: [1, 0]
                )
            ),
        ]

        let candidates = try EmbeddingIndexBuilder.build(embeddings: embeddings)

        XCTAssertTrue(candidates.isEmpty)
    }

    func testVectorGenerationIsPublishedAndReloadable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosVectorTests-(UUID().uuidString)", isDirectory: true)
        let paths = CachePaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.vectorGenerations,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let index = try RustHnswIndex(dimension: 2, maxNeighbors: 4, constructionEf: 32)
        try index.insert(label: 0, vector: [1, 0])
        try index.insert(label: 1, vector: [0, 1])
        let result = EmbeddingIndexBuildResult(
            candidates: [],
            indexData: try index.serializedData(),
            entries: [
                EmbeddingIndexEntry(
                    assetID: "asset-a",
                    sourceFingerprint: "source-a",
                    contentHash: nil
                ),
                EmbeddingIndexEntry(
                    assetID: "asset-b",
                    sourceFingerprint: "source-b",
                    contentHash: nil
                ),
            ],
            modelIdentifier: "test-model",
            algorithmVersion: "test-v1",
            metric: "cosine",
            dimension: 2
        )
        let store = VectorGenerationStore(paths: paths)

        try store.replace(with: result)
        let generation = try XCTUnwrap(store.loadCurrent())

        XCTAssertEqual(generation.manifest.entries, result.entries)
        XCTAssertEqual(generation.manifest.dimension, 2)
        XCTAssertEqual(generation.indexData, result.indexData)
        let reloadedIndex = try RustHnswIndex(serializedData: generation.indexData)
        let matches = try reloadedIndex.search(vector: [1, 0], limit: 1)
        XCTAssertEqual(matches.first?.label, 0)

        try store.replace(with: result)
        XCTAssertEqual(try store.removeSupersededGenerations(keeping: 0), 1)
        XCTAssertNotNil(try store.loadCurrent())

        try store.clearCurrent()
        XCTAssertNil(try store.loadCurrent())
    }
}
