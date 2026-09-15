import Foundation

enum ScanPhase: String, Codable, Sendable {
    case prepare
    case enumerate
    case fastFeatures = "fast_features"
    case embedding
    case index
    case verify
    case finalize
}

enum ScanSessionStatus: String, Codable, Sendable {
    case queued
    case running
    case pausing
    case paused
    case recovering
    case completed
    case cancelled
    case failed
}

struct ScanProgressSnapshot: Equatable, Sendable {
    let scanID: UUID?
    let status: ScanSessionStatus
    let phase: ScanPhase
    let discoveredCount: Int
    let committedCount: Int
    let failedCount: Int
    let missingCount: Int
    let totalBytes: Int64
    let processedBytes: Int64
    let isTotalKnown: Bool
    let lastPath: String?
    let lastError: String?
    let updatedAt: Date

    var fractionCompleted: Double? {
        guard isTotalKnown, totalBytes > 0 else {
            return nil
        }

        return min(max(Double(processedBytes) / Double(totalBytes), 0), 1)
    }

    static let idle = ScanProgressSnapshot(
        scanID: nil,
        status: .completed,
        phase: .prepare,
        discoveredCount: 0,
        committedCount: 0,
        failedCount: 0,
        missingCount: 0,
        totalBytes: 0,
        processedBytes: 0,
        isTotalKnown: false,
        lastPath: nil,
        lastError: nil,
        updatedAt: .now
    )
}

struct ResumableScan: Identifiable, Sendable {
    let id: UUID
    let rootID: UUID
    let rootURL: URL
    let bookmarkData: Data?
    let status: ScanSessionStatus
    let phase: ScanPhase
    let discoveredCount: Int
    let committedCount: Int
    let failedCount: Int
    let updatedAt: Date
}

struct FastFeatureRecord: Codable, Sendable {
    let sourceFingerprint: String
    let contentHash: String?
    let quickFingerprint: String?
    let perceptualHash: UInt64
    let thumbnailRelativePath: String
    let width: Int
    let height: Int
}

struct EmbeddingInput: Sendable {
    let assetID: String
    let sourceFingerprint: String
    let thumbnailRelativePath: String
}

struct IndexedEmbedding: Sendable {
    let assetID: String
    let sourceFingerprint: String
    let contentHash: String?
    let embedding: ImageEmbedding
}

struct ContentHashCandidate: Sendable {
    let assetID: String
    let path: String
    let sourceFingerprint: String
    let contentHash: String?
    let fileSize: Int64
}

struct ThumbnailObject: Sendable {
    let key: String
    let relativePath: String
}

struct CacheObjectRecord: Sendable {
    let key: String
    let relativePath: String
}

struct IndexedFastFeature: Sendable {
    let assetID: String
    let contentHash: String
    let perceptualHash: UInt64
}

struct DuplicateGroupRecord: Sendable {
    let id: String
    let assetIDs: [String]
    let confidence: Double
    let algorithmVersion: String
}

struct SimilarityCandidateRecord: Sendable {
    let id: String
    let assetAID: String
    let assetBID: String
    let relationKind: String
    let score: Double
    let evidenceJSON: String
    let algorithmVersion: String
}

enum ReviewDecision: String, Codable, Sendable {
    case keep
    case process
    case ignore
}

struct SimilarityReviewItem: Identifiable, Equatable, Sendable {
    let id: String
    let assetAID: String
    let assetAPath: String
    let assetASourceFingerprint: String
    let thumbnailARelativePath: String?
    let assetBID: String
    let assetBPath: String
    let assetBSourceFingerprint: String
    let thumbnailBRelativePath: String?
    let relationKind: String
    let score: Double
    let evidenceJSON: String
    let algorithmVersion: String
    let decision: ReviewDecision?
}

struct ResultIndexSummary: Sendable {
    let duplicateGroupCount: Int
    let similarityCandidateCount: Int
}

struct DiscoveredPhoto: Sendable {
    let assetID: String
    let rootID: UUID
    let path: String
    let fileResourceID: String?
    let sourceFingerprint: String
    let sizeBytes: Int64
    let modifiedAt: Date?
}

struct ScanRun: Sendable {
    let id: UUID
    let updates: AsyncStream<ScanProgressSnapshot>
    let metrics: ScanMetrics
}

actor ScanMetrics {
    private(set) var sourceBytesRead: Int64 = 0

    func addSourceBytes(_ bytes: Int64) {
        sourceBytesRead += max(bytes, 0)
    }

    func snapshot() -> Int64 {
        sourceBytesRead
    }
}

enum IndexPhotosError: LocalizedError {
    case cacheDirectoryUnavailable(URL, Error)
    case cacheInitializationFailed(Error)
    case anotherInstanceIsRunning
    case scanAlreadyRunning
    case noScanAvailable
    case sourceUnavailable(URL)
    case database(String)
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case let .cacheDirectoryUnavailable(url, error):
            return "无法创建缓存目录 \(url.path)：\(error.localizedDescription)"
        case let .cacheInitializationFailed(error):
            return "缓存初始化失败：\(error.localizedDescription)"
        case .anotherInstanceIsRunning:
            return "IndexPhotos 已在运行，请先关闭其他实例。"
        case .scanAlreadyRunning:
            return "已有扫描任务正在运行。"
        case .noScanAvailable:
            return "没有可恢复的扫描任务。"
        case let .sourceUnavailable(url):
            return "无法访问扫描目录：\(url.path)"
        case let .database(message):
            return "数据库错误：\(message)"
        case let .invalidState(message):
            return "无效状态：\(message)"
        }
    }
}
