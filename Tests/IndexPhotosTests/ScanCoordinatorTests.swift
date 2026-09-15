import Foundation
@testable import IndexPhotos
import XCTest

final class ScanCoordinatorTests: XCTestCase {
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
                await coordinator.requestPause()
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
        XCTAssertEqual(summary.similarityCandidateCount, 0)
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

        try await catalog.close()
    }
}
