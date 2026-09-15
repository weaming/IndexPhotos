import CoreGraphics
import Foundation
import ImageIO

struct GeometryImage: Sendable {
    let data: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

struct GeometryVerificationRecord: Sendable {
    let candidateID: String
    let evidenceJSON: String
}

struct GeometryVerifier {
    static let ALGORITHM_VERSION = "normalized-patch-affine-ransac-v1"
    private static let MAX_CANDIDATES = 5_000

    private let thumbnailStore: ThumbnailStore

    init(thumbnailStore: ThumbnailStore) {
        self.thumbnailStore = thumbnailStore
    }

    func makeSession() -> Session {
        Session(thumbnailStore: thumbnailStore)
    }

    func annotate(
        candidates: [SimilarityReviewItem]
    ) throws -> [GeometryVerificationRecord] {
        var session = makeSession()
        var records: [GeometryVerificationRecord] = []
        records.reserveCapacity(candidates.count)

        for candidate in candidates.prefix(Self.MAX_CANDIDATES) {
            if let record = try session.annotate(candidate: candidate) {
                records.append(record)
            }
        }
        return records
    }

    struct Session {
        private static let MAX_THUMBNAIL_PIXEL_SIZE = 320

        private let thumbnailStore: ThumbnailStore
        private var imageCache: [String: GeometryImage] = [:]

        init(thumbnailStore: ThumbnailStore) {
            self.thumbnailStore = thumbnailStore
        }

        mutating func annotate(
            candidate: SimilarityReviewItem
        ) throws -> GeometryVerificationRecord? {
            try Task.checkCancellation()
            guard !hasCurrentGeometryEvidence(
                candidate.evidenceJSON,
                assetASourceFingerprint: candidate.assetASourceFingerprint,
                assetBSourceFingerprint: candidate.assetBSourceFingerprint
            ) else {
                return nil
            }

            let leftImage = image(
                assetID: candidate.assetAID,
                relativePath: candidate.thumbnailARelativePath
            )
            let rightImage = image(
                assetID: candidate.assetBID,
                relativePath: candidate.thumbnailBRelativePath
            )
            let geometryEvidence: [String: Any]
            if let leftImage, let rightImage {
                do {
                    let result = try RustCore.verifyGeometry(
                        left: leftImage,
                        right: rightImage
                    )
                    geometryEvidence = [
                        "algorithm": GeometryVerifier.ALGORITHM_VERSION,
                        "status": "completed",
                        "assetASourceFingerprint": candidate.assetASourceFingerprint,
                        "assetBSourceFingerprint": candidate.assetBSourceFingerprint,
                        "matchedCount": Int(result.matchedCount),
                        "inlierCount": Int(result.inlierCount),
                        "inlierRatio": Double(result.inlierRatio),
                        "coverage": Double(result.coverage),
                        "medianError": Double(result.medianError),
                        "passed": result.passed,
                    ]
                } catch {
                    geometryEvidence = unavailableEvidence(
                        assetASourceFingerprint: candidate.assetASourceFingerprint,
                        assetBSourceFingerprint: candidate.assetBSourceFingerprint,
                        error: error
                    )
                }
            } else {
                geometryEvidence = [
                    "algorithm": GeometryVerifier.ALGORITHM_VERSION,
                    "status": "thumbnail_unavailable",
                    "assetASourceFingerprint": candidate.assetASourceFingerprint,
                    "assetBSourceFingerprint": candidate.assetBSourceFingerprint,
                ]
            }

            return GeometryVerificationRecord(
                candidateID: candidate.id,
                evidenceJSON: mergedEvidence(
                    candidate.evidenceJSON,
                    geometryEvidence
                )
            )
        }

        private mutating func image(
            assetID: String,
            relativePath: String?
        ) -> GeometryImage? {
            guard let relativePath else {
                return nil
            }
            if let cachedImage = imageCache[assetID] {
                return cachedImage
            }
            guard let data = try? thumbnailStore.load(relativePath: relativePath),
                  let image = makeImage(data: data)
            else {
                return nil
            }
            imageCache[assetID] = image
            return image
        }

        private func makeImage(data: Data) -> GeometryImage? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(
                      source,
                      0,
                      [
                          kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: Self.MAX_THUMBNAIL_PIXEL_SIZE,
                          kCGImageSourceShouldCache: false,
                          kCGImageSourceShouldCacheImmediately: true,
                      ] as CFDictionary
                  )
            else {
                return nil
            }

            let width = image.width
            let height = image.height
            let bytesPerRow = width * 4
            guard width > 0, height > 0 else {
                return nil
            }
            var rgbaData = Data(count: height * bytesPerRow)
            var didRender = false
            rgbaData.withUnsafeMutableBytes { buffer in
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
                return nil
            }
            return GeometryImage(
                data: rgbaData,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow
            )
        }

        private func hasCurrentGeometryEvidence(
            _ evidenceJSON: String,
            assetASourceFingerprint: String,
            assetBSourceFingerprint: String
        ) -> Bool {
            guard let data = evidenceJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  let geometry = dictionary["geometry"] as? [String: Any]
            else {
                return false
            }
            return geometry["algorithm"] as? String == GeometryVerifier.ALGORITHM_VERSION
                && geometry["status"] as? String == "completed"
                && geometry["assetASourceFingerprint"] as? String == assetASourceFingerprint
                && geometry["assetBSourceFingerprint"] as? String == assetBSourceFingerprint
        }

        private func unavailableEvidence(
            assetASourceFingerprint: String,
            assetBSourceFingerprint: String,
            error: Error
        ) -> [String: Any] {
            [
                "algorithm": GeometryVerifier.ALGORITHM_VERSION,
                "status": "failed",
                "assetASourceFingerprint": assetASourceFingerprint,
                "assetBSourceFingerprint": assetBSourceFingerprint,
                "error": error.localizedDescription,
            ]
        }

        private func mergedEvidence(
            _ sourceJSON: String,
            _ geometryEvidence: [String: Any]
        ) -> String {
            var object: [String: Any] = if let data = sourceJSON.data(using: .utf8),
                                            let decoded = try? JSONSerialization.jsonObject(with: data),
                                            let dictionary = decoded as? [String: Any]
            {
                dictionary
            } else {
                ["source": sourceJSON]
            }
            object["geometry"] = geometryEvidence
            guard let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ) else {
                return sourceJSON
            }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
