import Foundation
@testable import IndexPhotos
import XCTest

final class CatalogStoreTests: XCTestCase {
    func testEmbeddingCacheRequiresCurrentSourceFingerprint() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosEmbeddingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let catalog = try CatalogStore(
            databaseURL: directory.appendingPathComponent("catalog.sqlite")
        )
        let rootID = UUID()
        try await catalog.upsertRoot(
            id: rootID,
            displayName: "test",
            url: directory,
            bookmarkData: nil
        )
        let sessionID = try await catalog.createScanSession(rootID: rootID)
        let item = DiscoveredPhoto(
            assetID: "asset-embedding",
            rootID: rootID,
            path: directory.appendingPathComponent("photo.jpg").path,
            fileResourceID: nil,
            sourceFingerprint: "source-v1",
            sizeBytes: 1024,
            modifiedAt: nil
        )
        _ = try await catalog.registerDiscovered(item, sessionID: sessionID)
        _ = try await catalog.commitFastFeature(
            sessionID: sessionID,
            item: item,
            feature: FastFeatureResult(
                contentHash: "hash",
                perceptualHash: 1,
                thumbnailData: Data([1]),
                width: 1,
                height: 1
            ),
            thumbnail: ThumbnailObject(
                key: "thumbnail-embedding",
                relativePath: "thumbnails/small/embedding.jpg"
            )
        )

        let embedding = ImageEmbedding(
            modelIdentifier: "test-model",
            algorithmVersion: "test-embedding-v1",
            metric: "cosine",
            values: [0.6, 0.8]
        )
        try await catalog.commitEmbedding(
            assetID: item.assetID,
            sourceFingerprint: item.sourceFingerprint,
            embedding: embedding
        )

        let currentEmbedding = try await catalog.validEmbedding(
            assetID: item.assetID,
            sourceFingerprint: item.sourceFingerprint,
            algorithmVersion: embedding.algorithmVersion
        )
        XCTAssertEqual(currentEmbedding, embedding)

        let staleEmbedding = try await catalog.validEmbedding(
            assetID: item.assetID,
            sourceFingerprint: "source-v2",
            algorithmVersion: embedding.algorithmVersion
        )
        XCTAssertNil(staleEmbedding)

        let inputs = try await catalog.embeddingInputs()
        XCTAssertEqual(inputs.map(\.assetID), [item.assetID])
        let indexed = try await catalog.committedEmbeddings(
            algorithmVersion: embedding.algorithmVersion
        )
        XCTAssertEqual(indexed.map(\.assetID), [item.assetID])

        try await catalog.close()
    }

    func testQuickFingerprintCandidateCanBePromotedToFullHash() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosQuickFingerprintTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }

        let catalog = try CatalogStore(
            databaseURL: directory.appendingPathComponent("catalog.sqlite")
        )
        let rootID = UUID()
        try await catalog.upsertRoot(
            id: rootID,
            displayName: "test",
            url: directory,
            bookmarkData: nil
        )
        let sessionID = try await catalog.createScanSession(rootID: rootID)
        try await catalog.markSessionRunning(sessionID, phase: .fastFeatures)

        let items = [
            DiscoveredPhoto(
                assetID: "asset-a",
                rootID: rootID,
                path: directory.appendingPathComponent("a.jpg").path,
                fileResourceID: nil,
                sourceFingerprint: "fingerprint-a",
                sizeBytes: 5 * 1024 * 1024,
                modifiedAt: nil
            ),
            DiscoveredPhoto(
                assetID: "asset-b",
                rootID: rootID,
                path: directory.appendingPathComponent("b.jpg").path,
                fileResourceID: nil,
                sourceFingerprint: "fingerprint-b",
                sizeBytes: 5 * 1024 * 1024,
                modifiedAt: nil
            ),
        ]

        for item in items {
            _ = try await catalog.registerDiscovered(item, sessionID: sessionID)
            _ = try await catalog.commitFastFeature(
                sessionID: sessionID,
                item: item,
                feature: FastFeatureResult(
                    contentHash: nil,
                    perceptualHash: 1,
                    thumbnailData: Data([1]),
                    width: 1,
                    height: 1,
                    quickFingerprint: "quick"
                ),
                thumbnail: ThumbnailObject(
                    key: item.assetID,
                    relativePath: "thumbnails/small/\(item.assetID).jpg"
                )
            )
        }

        let candidates = try await catalog.quickFingerprintCandidates(
            sizeBytes: 5 * 1024 * 1024,
            quickFingerprint: "quick",
            excluding: "asset-b"
        )
        XCTAssertEqual(candidates.map(\.assetID), ["asset-a"])

        try await catalog.completeContentHash(
            assetID: "asset-a",
            sourceFingerprint: "fingerprint-a",
            contentHash: "hash-a"
        )
        let committedFeatures = try await catalog.committedFastFeatures()
        XCTAssertEqual(committedFeatures.map(\.assetID), ["asset-a"])

        try await catalog.close()
    }

    func testIncrementalCountersSurviveRetrySourceChangeAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosCounterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("catalog.sqlite")
        let catalog = try CatalogStore(databaseURL: databaseURL)
        let rootID = UUID()
        try await catalog.upsertRoot(id: rootID, displayName: "test", url: directory, bookmarkData: nil)
        let sessionID = try await catalog.createScanSession(rootID: rootID)
        try await catalog.markSessionRunning(sessionID, phase: .fastFeatures)

        func photo(fingerprint: String, size: Int64) -> DiscoveredPhoto {
            DiscoveredPhoto(assetID: "asset", rootID: rootID, path: "photo.jpg", fileResourceID: nil,
                            sourceFingerprint: fingerprint, sizeBytes: size, modifiedAt: nil)
        }
        let item = photo(fingerprint: "v1", size: 1024)
        let feature = FastFeatureResult(contentHash: "hash-v1", perceptualHash: 1,
                                        thumbnailData: Data([1]), width: 1, height: 1)
        let thumbnail = ThumbnailObject(key: "thumb-v1", relativePath: "thumbnails/small/v1.jpg")
        _ = try await catalog.registerDiscovered(item, sessionID: sessionID)
        _ = try await catalog.commitFastFeature(
            sessionID: sessionID,
            item: item,
            feature: feature,
            thumbnail: thumbnail
        )
        let repeated = try await catalog.registerDiscovered(item, sessionID: sessionID)
        XCTAssertEqual(repeated.discoveredCount, 1)
        XCTAssertEqual(repeated.committedCount, 1)
        XCTAssertEqual(repeated.processedBytes, 1024)

        _ = try await catalog.recordFeatureFailure(sessionID: sessionID, item: item, message: "retry")
        let failed = try await catalog.recordFeatureFailure(sessionID: sessionID, item: item, message: "retry again")
        XCTAssertEqual(failed.failedCount, 1)
        XCTAssertEqual(failed.committedCount, 0)
        XCTAssertEqual(failed.processedBytes, 0)
        let retried = try await catalog.commitFastFeature(
            sessionID: sessionID,
            item: item,
            feature: feature,
            thumbnail: thumbnail
        )
        XCTAssertEqual(retried.failedCount, 0)
        XCTAssertEqual(retried.committedCount, 1)

        let changedItem = photo(fingerprint: "v2", size: 2048)
        let changed = try await catalog.registerDiscovered(changedItem, sessionID: sessionID)
        XCTAssertEqual(changed.discoveredCount, 1)
        XCTAssertEqual(changed.committedCount, 0)
        XCTAssertEqual(changed.failedCount, 0)
        XCTAssertEqual(changed.totalBytes, 2048)
        XCTAssertEqual(changed.processedBytes, 0)
        let staleFeatures = try await catalog.committedFastFeatures()
        XCTAssertTrue(staleFeatures.isEmpty)
        let staleCache = try await catalog.validFastFeature(
            assetID: "asset",
            sourceFingerprint: "v2",
            algorithmVersion: "fast-v1"
        )
        XCTAssertNil(staleCache)

        let changedFeature = FastFeatureResult(contentHash: "hash-v2", perceptualHash: 2,
                                               thumbnailData: Data([2]), width: 1, height: 1)
        _ = try await catalog.commitFastFeature(sessionID: sessionID, item: changedItem, feature: changedFeature,
                                                thumbnail: ThumbnailObject(
                                                    key: "thumb-v2",
                                                    relativePath: "thumbnails/small/v2.jpg"
                                                ))
        try await catalog.close()
        let reopenedCatalog = try CatalogStore(databaseURL: databaseURL)
        try await reopenedCatalog.recoverInterruptedSessions()
        try await reopenedCatalog.markSessionRunning(sessionID, phase: .fastFeatures)
        let recovered = try await reopenedCatalog.progress(for: sessionID)
        XCTAssertEqual(recovered.discoveredCount, 1)
        XCTAssertEqual(recovered.committedCount, 1)
        XCTAssertEqual(recovered.failedCount, 0)
        XCTAssertEqual(recovered.processedBytes, 2048)
        try await reopenedCatalog.close()
    }

    func testBenchmarkCheckpointScaling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosCheckpointTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for count in [1000, 3000] {
            let catalog = try CatalogStore(databaseURL: directory.appendingPathComponent("catalog-\(count).sqlite"))
            let rootID = UUID()
            try await catalog.upsertRoot(id: rootID, displayName: "benchmark", url: directory, bookmarkData: nil)
            let sessionID = try await catalog.createScanSession(rootID: rootID)
            try await catalog.markSessionRunning(sessionID, phase: .fastFeatures)
            let clock = ContinuousClock()
            let startedAt = clock.now

            for index in 0 ..< count {
                let item = DiscoveredPhoto(
                    assetID: "asset-\(index)", rootID: rootID, path: "photo-\(index).jpg",
                    fileResourceID: nil, sourceFingerprint: "fingerprint-\(index)",
                    sizeBytes: 1024, modifiedAt: nil
                )
                _ = try await catalog.registerDiscovered(item, sessionID: sessionID)
                _ = try await catalog.reuseFastFeature(sessionID: sessionID, item: item)
            }

            print("BENCH checkpoints count=\(count) elapsed=\(startedAt.duration(to: clock.now))")
            let progress = try await catalog.progress(for: sessionID)
            XCTAssertEqual(progress.discoveredCount, count)
            XCTAssertEqual(progress.committedCount, count)
            XCTAssertEqual(progress.processedBytes, Int64(count * 1024))
            try await catalog.close()
        }
    }

    func testRootIDIsStableForTheSameDirectory() {
        let url = URL(fileURLWithPath: "/tmp/IndexPhotos")

        XCTAssertEqual(StableIdentifier.rootID(for: url), StableIdentifier.rootID(for: url))
    }

    func testEnumerationCheckpointCanBeReadBack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let catalog = try CatalogStore(
            databaseURL: directory.appendingPathComponent("catalog.sqlite")
        )
        let rootID = UUID()
        try await catalog.upsertRoot(
            id: rootID,
            displayName: "测试目录",
            url: directory,
            bookmarkData: nil
        )
        let sessionID = try await catalog.createScanSession(rootID: rootID)
        try await catalog.markSessionRunning(sessionID)

        let item = DiscoveredPhoto(
            assetID: "asset-1",
            rootID: rootID,
            path: directory.appendingPathComponent("one.jpg").path,
            fileResourceID: "resource-1",
            sourceFingerprint: "fingerprint-1",
            sizeBytes: 1024,
            modifiedAt: .now
        )
        let checkpoint = try await catalog.commitEnumerationBatch(
            sessionID: sessionID,
            items: [item],
            lastPath: item.path
        )

        XCTAssertEqual(checkpoint.discoveredCount, 1)
        XCTAssertEqual(checkpoint.committedCount, 1)
        XCTAssertEqual(checkpoint.totalBytes, 1024)
        XCTAssertEqual(checkpoint.lastPath, item.path)

        try await catalog.close()
    }

    func testInterruptedSessionBecomesResumable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let catalog = try CatalogStore(
            databaseURL: directory.appendingPathComponent("catalog.sqlite")
        )
        let rootID = UUID()
        try await catalog.upsertRoot(
            id: rootID,
            displayName: "测试目录",
            url: directory,
            bookmarkData: nil
        )
        let sessionID = try await catalog.createScanSession(rootID: rootID)
        try await catalog.markSessionRunning(sessionID)

        try await catalog.recoverInterruptedSessions()
        let resumableScan = try await catalog.latestResumableScan()

        XCTAssertEqual(resumableScan?.id, sessionID)
        XCTAssertEqual(resumableScan?.status, .recovering)

        try await catalog.close()
    }

    func testCacheObjectIsReplacedAndUnreferencedObjectCanBeRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let catalog = try CatalogStore(
            databaseURL: directory.appendingPathComponent("catalog.sqlite")
        )
        let rootID = UUID()
        try await catalog.upsertRoot(
            id: rootID,
            displayName: "测试目录",
            url: directory,
            bookmarkData: nil
        )
        let sessionID = try await catalog.createScanSession(rootID: rootID)
        let thumbnailStore = ThumbnailStore(
            storageDirectory: directory.appendingPathComponent("cache", isDirectory: true)
        )

        let firstItem = DiscoveredPhoto(
            assetID: "asset-1",
            rootID: rootID,
            path: directory.appendingPathComponent("one.jpg").path,
            fileResourceID: "resource-1",
            sourceFingerprint: "fingerprint-1",
            sizeBytes: 1024,
            modifiedAt: .now
        )
        _ = try await catalog.registerDiscovered(firstItem, sessionID: sessionID)
        let firstThumbnail = try thumbnailStore.store(
            assetID: firstItem.assetID,
            sourceFingerprint: firstItem.sourceFingerprint,
            data: Data([1, 2, 3])
        )
        _ = try await catalog.commitFastFeature(
            sessionID: sessionID,
            item: firstItem,
            feature: FastFeatureResult(
                contentHash: "hash-1",
                perceptualHash: 1,
                thumbnailData: Data([1, 2, 3]),
                width: 1,
                height: 1
            ),
            thumbnail: firstThumbnail
        )

        let secondItem = DiscoveredPhoto(
            assetID: firstItem.assetID,
            rootID: rootID,
            path: firstItem.path,
            fileResourceID: firstItem.fileResourceID,
            sourceFingerprint: "fingerprint-2",
            sizeBytes: 2048,
            modifiedAt: .now
        )
        _ = try await catalog.registerDiscovered(secondItem, sessionID: sessionID)
        let secondThumbnail = try thumbnailStore.store(
            assetID: secondItem.assetID,
            sourceFingerprint: secondItem.sourceFingerprint,
            data: Data([4, 5, 6])
        )
        _ = try await catalog.commitFastFeature(
            sessionID: sessionID,
            item: secondItem,
            feature: FastFeatureResult(
                contentHash: "hash-2",
                perceptualHash: 2,
                thumbnailData: Data([4, 5, 6]),
                width: 1,
                height: 1
            ),
            thumbnail: secondThumbnail
        )

        let maintenance = CacheMaintenance(
            catalog: catalog,
            thumbnailStore: thumbnailStore
        )
        let removedCount = try await maintenance.removeUnreferencedObjects()

        XCTAssertEqual(removedCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("cache")
                    .appendingPathComponent(firstThumbnail.relativePath)
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("cache")
                    .appendingPathComponent(secondThumbnail.relativePath)
                    .path
            )
        )

        try await catalog.close()
    }

    func testResultIndexerSeparatesExactAndSimilarResults() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosResultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let catalog = try CatalogStore(
            databaseURL: directory.appendingPathComponent("catalog.sqlite")
        )
        let rootID = UUID()
        try await catalog.upsertRoot(
            id: rootID,
            displayName: "测试目录",
            url: directory,
            bookmarkData: nil
        )
        let sessionID = try await catalog.createScanSession(rootID: rootID)
        let items = [
            DiscoveredPhoto(
                assetID: "asset-a",
                rootID: rootID,
                path: directory.appendingPathComponent("a.jpg").path,
                fileResourceID: "resource-a",
                sourceFingerprint: "fingerprint-a",
                sizeBytes: 1024,
                modifiedAt: .now
            ),
            DiscoveredPhoto(
                assetID: "asset-b",
                rootID: rootID,
                path: directory.appendingPathComponent("b.jpg").path,
                fileResourceID: "resource-b",
                sourceFingerprint: "fingerprint-b",
                sizeBytes: 1024,
                modifiedAt: .now
            ),
            DiscoveredPhoto(
                assetID: "asset-c",
                rootID: rootID,
                path: directory.appendingPathComponent("c.jpg").path,
                fileResourceID: "resource-c",
                sourceFingerprint: "fingerprint-c",
                sizeBytes: 1024,
                modifiedAt: .now
            ),
        ]
        let contentHashes = ["same-bytes", "same-bytes", "edited-bytes"]
        let perceptualHashes: [UInt64] = [0, 0, 1]

        for index in items.indices {
            let item = items[index]
            _ = try await catalog.registerDiscovered(item, sessionID: sessionID)
            _ = try await catalog.commitFastFeature(
                sessionID: sessionID,
                item: item,
                feature: FastFeatureResult(
                    contentHash: contentHashes[index],
                    perceptualHash: perceptualHashes[index],
                    thumbnailData: Data([UInt8(index)]),
                    width: 1,
                    height: 1
                ),
                thumbnail: ThumbnailObject(
                    key: "thumbnail-\(index)",
                    relativePath: "thumbnails/small/thumbnail-\(index).jpg"
                )
            )
        }

        let indexer = ResultIndexer(catalog: catalog)
        let summary = try await indexer.rebuild()
        let storedSummary = try await catalog.resultSummary()

        XCTAssertEqual(summary.duplicateGroupCount, 1)
        XCTAssertEqual(summary.similarityCandidateCount, 2)
        XCTAssertEqual(storedSummary.duplicateGroupCount, 1)
        XCTAssertEqual(storedSummary.similarityCandidateCount, 2)

        let initialCandidates = try await catalog.similarityCandidates(
            rootID: rootID
        )
        XCTAssertEqual(initialCandidates.count, 2)
        let geometryEvidence = #"{"geometry":{"algorithm":"test-geometry-v1","status":"completed"}}"#
        let geometryCandidate = try XCTUnwrap(initialCandidates.first)
        try await catalog.updateSimilarityEvidence(
            candidateID: geometryCandidate.id,
            evidenceJSON: geometryEvidence
        )
        _ = try await indexer.rebuild()
        let rebuiltCandidates = try await catalog.similarityCandidates(
            rootID: rootID,
            includeReviewed: true
        )
        XCTAssertEqual(
            rebuiltCandidates.first(where: { $0.id == geometryCandidate.id })?.evidenceJSON,
            geometryEvidence
        )

        let pendingCandidates = try await catalog.similarityCandidates(
            rootID: rootID
        )
        XCTAssertEqual(pendingCandidates.count, 2)
        let reviewedCandidate = try XCTUnwrap(pendingCandidates.first)
        try await catalog.setReviewDecision(
            candidateID: reviewedCandidate.id,
            decision: .process,
            note: "待后续人工处理"
        )

        let remainingCandidates = try await catalog.similarityCandidates(
            rootID: rootID
        )
        XCTAssertEqual(remainingCandidates.count, 1)

        let allCandidates = try await catalog.similarityCandidates(
            rootID: rootID,
            includeReviewed: true
        )
        XCTAssertEqual(allCandidates.count, 2)
        XCTAssertEqual(
            allCandidates.first(where: { $0.id == reviewedCandidate.id })?.decision,
            .process
        )

        try await catalog.clearReviewDecision(candidateID: reviewedCandidate.id)
        let clearedCandidates = try await catalog.similarityCandidates(rootID: rootID)
        XCTAssertEqual(clearedCandidates.count, 2)

        try await catalog.close()
    }
}
