import Foundation
@testable import IndexPhotos
import XCTest

final class ScanCoordinatorTests: XCTestCase {
    func testSameVolumeAllowsOnlyOneActiveDirectoryScan() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosVolumeLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let data = try XCTUnwrap(
            Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )
        )
        for index in 0 ..< 200 {
            try data.write(to: directory.appendingPathComponent("photo-\(index).png"))
        }

        let catalog = try CatalogStore(
            databaseURL: directory.appendingPathComponent("catalog.sqlite")
        )
        let firstRootID = UUID()
        let secondRootID = UUID()
        try await catalog.upsertRoot(
            id: firstRootID,
            displayName: "第一个目录",
            url: directory,
            bookmarkData: nil
        )
        try await catalog.upsertRoot(
            id: secondRootID,
            displayName: "第二个目录",
            url: directory,
            bookmarkData: nil
        )

        let coordinator = ScanCoordinator(
            catalog: catalog,
            thumbnailStore: ThumbnailStore(
                storageDirectory: directory.appendingPathComponent("cache")
            )
        )
        let firstRun = try await coordinator.start(
            rootID: firstRootID,
            rootURL: directory
        )

        do {
            _ = try await coordinator.start(
                rootID: secondRootID,
                rootURL: directory
            )
            XCTFail("同一存储卷不应同时开始第二个扫描")
        } catch let error as IndexPhotosError {
            guard case .scanAlreadyRunningOnVolume = error else {
                XCTFail("收到错误：\(error.localizedDescription)")
                return
            }
        }

        await coordinator.requestCancel(rootID: firstRootID)
        for await _ in firstRun.updates {}
        try await catalog.close()
    }

    func testPausedScanResumesWithoutDoubleCounting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosResumeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let data =
            try XCTUnwrap(
                Data(
                    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
                )
            )
        for index in 0 ..< 40 {
            try data.write(to: directory.appendingPathComponent("photo-\(index).png"))
        }
        let catalog = try CatalogStore(databaseURL: directory.appendingPathComponent("catalog.sqlite"))
        let rootID = UUID()
        try await catalog.upsertRoot(id: rootID, displayName: "test", url: directory, bookmarkData: nil)
        let coordinator = ScanCoordinator(
            catalog: catalog,
            thumbnailStore: ThumbnailStore(storageDirectory: directory.appendingPathComponent("cache"))
        )
        let run = try await coordinator.start(rootID: rootID, rootURL: directory)
        var pausedProgress = ScanProgressSnapshot.idle
        for await progress in run.updates {
            if progress.status == .running, progress.committedCount >= 16 {
                await coordinator.requestPause(rootID: rootID)
            }
            pausedProgress = progress
        }
        XCTAssertEqual(pausedProgress.status, .paused)
        XCTAssertGreaterThanOrEqual(pausedProgress.committedCount, 16)

        let resumedRun = try await coordinator.start(rootID: rootID, rootURL: directory, existingSessionID: run.id)
        var finalProgress = ScanProgressSnapshot.idle
        for await progress in resumedRun.updates {
            finalProgress = progress
        }
        XCTAssertEqual(finalProgress.status, .completed)
        XCTAssertEqual(finalProgress.discoveredCount, 40)
        XCTAssertEqual(finalProgress.committedCount, 40)
        XCTAssertEqual(finalProgress.failedCount, 0)
        XCTAssertEqual(finalProgress.processedBytes, Int64(data.count * 40))
        let summary = try await catalog.resultSummary()
        XCTAssertEqual(summary.duplicateGroupCount, 1)
        XCTAssertEqual(summary.similarityCandidateCount, 39)
        try await catalog.close()
    }

    func testDirectoryScanCommitsPhotoAndFinishes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosScanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let photoURL = directory.appendingPathComponent("portrait.png")
        let pngData =
            try XCTUnwrap(
                Data(
                    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
                )
            )
        try pngData.write(to: photoURL)

        let cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheDirectory.appendingPathComponent("work", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: cacheDirectory.appendingPathComponent("thumbnails/small", isDirectory: true),
            withIntermediateDirectories: true
        )
        try pngData.write(to: cacheDirectory.appendingPathComponent("thumbnails/small/cached.png"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("directory.jpg", isDirectory: true),
            withIntermediateDirectories: true
        )

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

        let thumbnailStore = ThumbnailStore(storageDirectory: cacheDirectory)
        let coordinator = ScanCoordinator(
            catalog: catalog,
            thumbnailStore: thumbnailStore
        )
        let run = try await coordinator.start(rootID: rootID, rootURL: directory)
        var finalSnapshot: ScanProgressSnapshot?

        for await snapshot in run.updates {
            finalSnapshot = snapshot
        }

        XCTAssertEqual(finalSnapshot?.status, .completed)
        XCTAssertEqual(finalSnapshot?.phase, .finalize)
        XCTAssertEqual(finalSnapshot?.discoveredCount, 1)
        XCTAssertEqual(finalSnapshot?.committedCount, 1)
        XCTAssertEqual(finalSnapshot?.isTotalKnown, true)

        try FileManager.default.removeItem(at: photoURL)
        let rescan = try await coordinator.start(rootID: rootID, rootURL: directory)
        var rescanSnapshot: ScanProgressSnapshot?
        for await snapshot in rescan.updates {
            rescanSnapshot = snapshot
        }

        XCTAssertEqual(rescanSnapshot?.status, .completed)
        XCTAssertEqual(rescanSnapshot?.missingCount, 1)
        let remainingEmbeddingInputs = try await catalog.embeddingInputs(rootID: rootID)
        XCTAssertTrue(remainingEmbeddingInputs.isEmpty)

        try await catalog.close()
    }

    func testRawPhotoIsSkippedWhenSiblingNonRawPhotoExists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosRawSiblingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pngData = try XCTUnwrap(
            Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )
        )
        try pngData.write(to: directory.appendingPathComponent("portrait.JPG"))
        try Data("not a raw image".utf8).write(
            to: directory.appendingPathComponent("portrait.ARW")
        )

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
        let coordinator = ScanCoordinator(
            catalog: catalog,
            thumbnailStore: ThumbnailStore(
                storageDirectory: directory.appendingPathComponent("cache")
            )
        )

        let run = try await coordinator.start(rootID: rootID, rootURL: directory)
        var finalSnapshot: ScanProgressSnapshot?
        for await snapshot in run.updates {
            finalSnapshot = snapshot
        }

        XCTAssertEqual(finalSnapshot?.status, .completed)
        XCTAssertEqual(finalSnapshot?.discoveredCount, 1)
        XCTAssertEqual(finalSnapshot?.committedCount, 1)
        XCTAssertEqual(finalSnapshot?.failedCount, 0)
        try await catalog.close()
    }
}
