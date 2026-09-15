import Foundation
@testable import IndexPhotos
import XCTest

final class FastFeatureExtractorTests: XCTestCase {
    func testReadAheadAndRewindReadSmallSourceOnlyOnce() throws {
        let data = Data((0 ..< 4097).map { UInt8(truncatingIfNeeded: $0) })
        try withReader(data: data, cacheLimit: 8192) { reader, _ in
            var bytes = [UInt8](repeating: 0, count: 17)
            let readCount = bytes.withUnsafeMutableBytes { reader.readBytes(into: $0.baseAddress!, count: $0.count) }
            XCTAssertEqual(readCount, 17)
            XCTAssertEqual(Data(bytes), data.prefix(17))
            XCTAssertEqual(reader.readCallCount, 1)
            XCTAssertEqual(reader.sourceBytesRead, 1024)

            reader.rewind()
            XCTAssertEqual(reader.skipForward(count: Int64(data.count + 10)), Int64(data.count))
            reader.rewind()
            XCTAssertEqual(reader.skipForward(count: Int64(data.count)), Int64(data.count))
            XCTAssertEqual(try reader.finishHashing(), try RustCore.blake3Hex(data))
            XCTAssertEqual(reader.sourceBytesRead, Int64(data.count))
            XCTAssertEqual(reader.cachedByteCount, data.count)
        }
    }

    func testBoundedCacheAndRewindPreserveHash() throws {
        let data = Data((0 ..< 4097).map { UInt8(truncatingIfNeeded: $0) })
        try withReader(data: data, cacheLimit: 1536) { reader, _ in
            XCTAssertEqual(reader.skipForward(count: Int64(data.count)), Int64(data.count))
            reader.rewind()
            XCTAssertEqual(reader.skipForward(count: Int64(data.count)), Int64(data.count))
            XCTAssertEqual(try reader.finishHashing(), try RustCore.blake3Hex(data))
            XCTAssertEqual(reader.cachedByteCount, 1536)
            XCTAssertLessThanOrEqual(reader.sourceBytesRead, Int64(data.count * 2))
        }
    }

    func testFinishHashingOnlyReadsUnhashedTail() throws {
        let data = Data(repeating: 73, count: 4097)
        try withReader(data: data, cacheLimit: 2048) { reader, _ in
            XCTAssertEqual(reader.skipForward(count: 17), 17)
            reader.rewind()
            XCTAssertEqual(reader.skipForward(count: 13), 13)
            XCTAssertEqual(try reader.finishHashing(), try RustCore.blake3Hex(data))
            XCTAssertEqual(reader.sourceBytesRead, Int64(data.count))
        }
    }

    func testSameSizeSourceChangeInvalidatesExtraction() throws {
        try withReader(data: Data(repeating: 0, count: 4097), cacheLimit: 8192) { reader, url in
            XCTAssertEqual(reader.skipForward(count: 1), 1)
            let writer = try FileHandle(forWritingTo: url)
            try writer.write(contentsOf: Data(repeating: 1, count: 4097))
            try writer.close()
            try FileManager.default.setAttributes(
                [.modificationDate: Date.now.addingTimeInterval(2)],
                ofItemAtPath: url.path
            )
            XCTAssertThrowsError(try reader.finishHashing())
        }
    }

    private func withReader(
        data: Data,
        cacheLimit: Int,
        body: (StreamingImageReader, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.bin")
        try data.write(to: url)
        let reader = try StreamingImageReader(
            url: url,
            expectedFileSize: Int64(data.count),
            readChunkSize: 1024,
            prefixCacheLimit: cacheLimit
        )

        do {
            try body(reader, url)
            try reader.close()
        } catch {
            try reader.close()
            throw error
        }
    }

    func testStreamingExtractionHashesCompleteSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexPhotosFeatureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let photoURL = directory.appendingPathComponent("portrait.png")
        let sourceData =
            try XCTUnwrap(
                Data(
                    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
                )
            )
        try sourceData.write(to: photoURL)

        let result = try FastFeatureExtractor().extract(
            url: photoURL,
            fileSize: Int64(sourceData.count)
        )

        XCTAssertEqual(result.contentHash, try RustCore.blake3Hex(sourceData))
        XCTAssertFalse(result.thumbnailData.isEmpty)
        XCTAssertGreaterThan(result.width, 0)
        XCTAssertGreaterThan(result.height, 0)
    }
}
