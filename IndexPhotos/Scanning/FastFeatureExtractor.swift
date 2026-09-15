import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct FastFeatureResult: Sendable {
    let contentHash: String
    let perceptualHash: UInt64
    let thumbnailData: Data
    let width: Int
    let height: Int
}

struct FastFeatureExtractor {
    private static let MAX_THUMBNAIL_PIXEL_SIZE = 320
    private static let JPEG_QUALITY = 0.82

    func extract(url: URL, fileSize: Int64) throws -> FastFeatureResult {
        let reader = try StreamingImageReader(url: url, expectedFileSize: fileSize)

        do {
            let result = try extract(reader: reader, url: url)
            try reader.close()
            return result
        } catch {
            let extractionError = error
            do {
                try reader.close()
            } catch {
                throw FeatureExtractionError.sourceReadFailed(
                    url,
                    "\(extractionError.localizedDescription)；关闭文件失败：\(error.localizedDescription)"
                )
            }
            try Task.checkCancellation()
            throw extractionError
        }
    }

    private func extract(reader: StreamingImageReader, url: URL) throws -> FastFeatureResult {
        let source = try reader.makeSource()
        guard CGImageSourceGetCount(source) > 0 else {
            throw FeatureExtractionError.invalidImage(url)
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let thumbnail = try makeThumbnail(source: source)
        let thumbnailData = try encodeJPEG(thumbnail)
        let rgba = try renderRGBA(thumbnail)
        let perceptualHash = try RustCore.perceptualHash(
            rgbaData: rgba.data,
            width: rgba.width,
            height: rgba.height,
            bytesPerRow: rgba.bytesPerRow
        )
        let contentHash = try reader.finishHashing()

        return FastFeatureResult(
            contentHash: contentHash,
            perceptualHash: perceptualHash,
            thumbnailData: thumbnailData,
            width: width > 0 ? width : thumbnail.width,
            height: height > 0 ? height : thumbnail.height
        )
    }

    private func makeThumbnail(source: CGImageSource) throws -> CGImage {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.MAX_THUMBNAIL_PIXEL_SIZE,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw FeatureExtractionError.thumbnailUnavailable
        }
        return thumbnail
    }

    private func encodeJPEG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw FeatureExtractionError.thumbnailEncodingFailed
        }

        let properties = [
            kCGImageDestinationLossyCompressionQuality: Self.JPEG_QUALITY,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw FeatureExtractionError.thumbnailEncodingFailed
        }
        return data as Data
    }

    private func renderRGBA(_ image: CGImage) throws -> RGBAImage {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var data = Data(count: height * bytesPerRow)
        var didRender = false

        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return
            }

            context.interpolationQuality = .medium
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            didRender = true
        }

        guard didRender else {
            throw FeatureExtractionError.pixelBufferUnavailable
        }
        return RGBAImage(
            data: data,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }
}

final class StreamingImageReader {
    private static let READ_CHUNK_SIZE = 1024 * 1024
    private static let PREFIX_CACHE_LIMIT = 32 * 1024 * 1024

    private let file: FileHandle
    private let url: URL
    private let expectedFileSize: Int64
    private let hasher: RustBlake3Hasher
    private let initialFileState: SourceFileState
    private let readChunkSize: Int
    private let prefixCacheLimit: Int
    private var prefixCache = Data()
    private var readChunk = Data()
    private var chunkOffset: Int64 = -1
    private var physicalOffset: Int64 = 0
    private var fileOffset: Int64 = 0
    private var hashedOffset: Int64 = 0
    private var isClosed = false
    private var callbackError: Error?
    private(set) var readCallCount = 0
    private(set) var sourceBytesRead: Int64 = 0
    var cachedByteCount: Int {
        prefixCache.count
    }

    init(
        url: URL,
        expectedFileSize: Int64,
        readChunkSize: Int = READ_CHUNK_SIZE,
        prefixCacheLimit: Int = PREFIX_CACHE_LIMIT
    ) throws {
        guard readChunkSize > 0, prefixCacheLimit >= 0 else {
            throw IndexPhotosError.invalidState("读取块大小或缓存上限无效")
        }

        let hasher = try RustBlake3Hasher()
        let file = try FileHandle(forReadingFrom: url)
        let fileState: SourceFileState
        do {
            fileState = try Self.readFileState(file, url: url)
            guard expectedFileSize < 0 || fileState.sizeBytes == expectedFileSize else {
                throw FeatureExtractionError.sourceReadFailed(url, "文件在扫描期间发生变化。")
            }
        } catch {
            try file.close()
            throw error
        }

        self.file = file
        self.url = url
        self.expectedFileSize = expectedFileSize
        self.hasher = hasher
        initialFileState = fileState
        self.readChunkSize = readChunkSize
        self.prefixCacheLimit = prefixCacheLimit
    }

    func close() throws {
        guard !isClosed else { return }
        try file.close()
        isClosed = true
    }

    func makeSource() throws -> CGImageSource {
        let retainedReader = Unmanaged.passRetained(self)
        var callbacks = CGDataProviderSequentialCallbacks(
            version: 0,
            getBytes: Self.getBytesCallback,
            skipForward: Self.skipForwardCallback,
            rewind: Self.rewindCallback,
            releaseInfo: Self.releaseInfoCallback
        )

        guard let provider = CGDataProvider(
            sequentialInfo: retainedReader.toOpaque(),
            callbacks: &callbacks
        ) else {
            retainedReader.release()
            throw FeatureExtractionError.dataProviderUnavailable(url)
        }

        let options = [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithDataProvider(provider, options) else {
            throw FeatureExtractionError.invalidImage(url)
        }
        return source
    }

    func finishHashing() throws -> String {
        if let callbackError {
            throw FeatureExtractionError.sourceReadFailed(
                url,
                callbackError.localizedDescription
            )
        }

        fileOffset = hashedOffset
        while let buffer = try availableBuffer() {
            fileOffset += Int64(buffer.data.count - buffer.offset)
        }

        let finalFileState = try Self.readFileState(file, url: url)
        guard finalFileState == initialFileState,
              hashedOffset == finalFileState.sizeBytes,
              expectedFileSize < 0 || hashedOffset == expectedFileSize
        else {
            throw FeatureExtractionError.sourceReadFailed(url, "文件在扫描期间发生变化。")
        }
        return try hasher.finalize()
    }

    func readBytes(into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        guard count > 0, callbackError == nil else {
            return 0
        }

        do {
            guard let source = try availableBuffer() else { return 0 }
            let readCount = min(count, source.data.count - source.offset)
            source.data.withUnsafeBytes { sourceBuffer in
                if let sourceAddress = sourceBuffer.baseAddress {
                    buffer.copyMemory(from: sourceAddress.advanced(by: source.offset), byteCount: readCount)
                }
            }
            fileOffset += Int64(readCount)
            return readCount
        } catch {
            callbackError = error
            return 0
        }
    }

    func skipForward(count: Int64) -> Int64 {
        guard count > 0, callbackError == nil else {
            return 0
        }

        var remaining = count
        var skipped: Int64 = 0
        do {
            while remaining > 0 {
                guard let buffer = try availableBuffer() else { break }
                let readCount = min(remaining, Int64(buffer.data.count - buffer.offset))
                fileOffset += readCount
                skipped += readCount
                remaining -= readCount
            }
            return skipped
        } catch {
            callbackError = error
            return skipped
        }
    }

    func rewind() {
        fileOffset = 0
    }

    private func availableBuffer() throws -> (data: Data, offset: Int)? {
        try Task.checkCancellation()
        guard !isClosed else {
            throw FeatureExtractionError.sourceReadFailed(url, "文件已关闭。")
        }
        if fileOffset < Int64(prefixCache.count) {
            return (prefixCache, Int(fileOffset))
        }
        let chunkEnd = chunkOffset + Int64(readChunk.count)
        if fileOffset >= chunkOffset, fileOffset < chunkEnd {
            return (readChunk, Int(fileOffset - chunkOffset))
        }

        if physicalOffset != fileOffset {
            try file.seek(toOffset: UInt64(fileOffset))
            physicalOffset = fileOffset
        }
        let data = try file.read(upToCount: readChunkSize) ?? Data()
        readCallCount += 1
        sourceBytesRead += Int64(data.count)
        physicalOffset += Int64(data.count)
        guard !data.isEmpty else { return nil }

        try appendToHash(data, startingAt: fileOffset)
        if fileOffset == Int64(prefixCache.count), prefixCache.count < prefixCacheLimit {
            prefixCache.append(data.prefix(prefixCacheLimit - prefixCache.count))
        }
        readChunk = data
        chunkOffset = fileOffset
        return (data, 0)
    }

    private static func readFileState(_ file: FileHandle, url: URL) throws -> SourceFileState {
        var metadata = stat()
        guard fstat(file.fileDescriptor, &metadata) == 0 else {
            throw FeatureExtractionError.sourceReadFailed(url, String(cString: strerror(errno)))
        }
        return SourceFileState(
            sizeBytes: metadata.st_size,
            modifiedSeconds: metadata.st_mtimespec.tv_sec,
            modifiedNanoseconds: metadata.st_mtimespec.tv_nsec,
            changedSeconds: metadata.st_ctimespec.tv_sec,
            changedNanoseconds: metadata.st_ctimespec.tv_nsec
        )
    }

    private func appendToHash(_ data: Data, startingAt startOffset: Int64) throws {
        let endOffset = startOffset + Int64(data.count)
        guard endOffset > hashedOffset else {
            return
        }
        guard startOffset <= hashedOffset else {
            throw StreamingImageReaderError.nonContiguousRead
        }

        let skippedBytes = Int(hashedOffset - startOffset)
        try data.withUnsafeBytes { buffer in
            let byteBuffer = buffer.bindMemory(to: UInt8.self)
            let suffix = UnsafeRawBufferPointer(
                start: byteBuffer.baseAddress?.advanced(by: skippedBytes),
                count: data.count - skippedBytes
            )
            try hasher.update(suffix)
        }
        hashedOffset = endOffset
    }

    private static let getBytesCallback: CGDataProviderGetBytesCallback = {
        info,
        buffer,
        count in
        guard let info else {
            return 0
        }
        let reader = Unmanaged<StreamingImageReader>
            .fromOpaque(info)
            .takeUnretainedValue()
        return reader.readBytes(into: buffer, count: count)
    }

    private static let skipForwardCallback: CGDataProviderSkipForwardCallback = {
        info,
        count in
        guard let info else {
            return 0
        }
        let reader = Unmanaged<StreamingImageReader>
            .fromOpaque(info)
            .takeUnretainedValue()
        return reader.skipForward(count: count)
    }

    private static let rewindCallback: CGDataProviderRewindCallback = { info in
        guard let info else {
            return
        }
        let reader = Unmanaged<StreamingImageReader>
            .fromOpaque(info)
            .takeUnretainedValue()
        reader.rewind()
    }

    private static let releaseInfoCallback: CGDataProviderReleaseInfoCallback = { info in
        guard let info else {
            return
        }
        Unmanaged<StreamingImageReader>
            .fromOpaque(info)
            .release()
    }
}

private struct SourceFileState: Equatable {
    let sizeBytes: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
}

private enum StreamingImageReaderError: LocalizedError {
    case nonContiguousRead

    var errorDescription: String? {
        "图像解码器请求了非连续的数据范围。"
    }
}

private struct RGBAImage {
    let data: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

enum FeatureExtractionError: LocalizedError {
    case invalidImage(URL)
    case dataProviderUnavailable(URL)
    case thumbnailUnavailable
    case thumbnailEncodingFailed
    case pixelBufferUnavailable
    case sourceReadFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case let .invalidImage(url):
            "无法解码图片：\(url.path)"
        case let .dataProviderUnavailable(url):
            "无法创建图片数据流：\(url.path)"
        case .thumbnailUnavailable:
            "无法生成图片缩略图。"
        case .thumbnailEncodingFailed:
            "无法保存图片缩略图。"
        case .pixelBufferUnavailable:
            "无法生成图片像素缓冲区。"
        case let .sourceReadFailed(url, reason):
            "读取图片失败：\(url.path)（\(reason)）"
        }
    }
}
