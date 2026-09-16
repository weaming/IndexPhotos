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

struct SavedRoot: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let url: URL
    let bookmarkData: Data?
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

enum SimilarityReviewPolicy {
    static let MIN_SCORE = 0.7
}

enum PhotoDeletionMode: String, Identifiable, Sendable {
    case trash
    case permanent

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .trash:
            return "移到废纸篓"
        case .permanent:
            return "永久删除"
        }
    }
}

struct PhotoDeletionTarget: Sendable, Equatable {
    let assetID: String
    let path: String
    let sourceFingerprint: String
}

struct PhotoDeletionReport: Sendable, Equatable {
    let deletedCount: Int
    let failedPaths: [String]
}

enum SimilarityAlgorithmFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case phash
    case vision

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all:
            return "全部来源"
        case .phash:
            return "phash"
        case .vision:
            return "vision"
        }
    }

    var algorithmVersion: String? {
        switch self {
        case .all:
            return nil
        case .phash:
            return "fast-phash-v1"
        case .vision:
            return "vision-hnsw-v1"
        }
    }
}

enum ReviewDecision: String, Codable, Sendable {
    case keep
    case deleteA = "delete_a"
    case deleteB = "delete_b"
    case process
    case ignore
}

enum SimilarityPagePosition: Sendable {
    case first
    case after(score: Double, id: String)
    case before(score: Double, id: String)
    case last
}

struct SimilarityScoreBucket: Hashable, Identifiable, Sendable {
    static let all = SimilarityScoreBucket(index: nil)
    static let firstIndex = min(
        max(Int(ceil(SimilarityReviewPolicy.MIN_SCORE * 10)), 0),
        9
    )
    static let values = (firstIndex..<10).map { SimilarityScoreBucket(index: $0) }
    static let valuesDescending = values.reversed()

    let index: Int?

    init(index: Int?) {
        self.index = index
    }

    var id: String {
        index.map(String.init) ?? "all"
    }

    var countIndex: Int? {
        guard let index else {
            return nil
        }
        return index - Self.firstIndex
    }

    var lowerBound: Double? {
        guard let index else {
            return nil
        }
        return Double(index) / 10
    }

    var upperBound: Double? {
        guard let index, index < 9 else {
            return nil
        }
        return Double(index + 1) / 10
    }

    var title: String {
        guard let index else {
            return "全部"
        }
        return String(
            format: "%.1f–%.1f",
            Double(index) / 10,
            Double(index + 1) / 10
        )
    }
}

struct SimilarityReviewItem: Identifiable, Equatable, Sendable {
    let id: String
    let assetAID: String
    let assetAPath: String
    let assetASizeBytes: Int64
    let assetASourceFingerprint: String
    let thumbnailARelativePath: String?
    let assetBID: String
    let assetBPath: String
    let assetBSizeBytes: Int64
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
    let rootID: UUID
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
    case scanAlreadyRunningOnVolume(URL)
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
        case let .scanAlreadyRunningOnVolume(url):
            return "同一磁盘已有目录正在扫描，请先等待当前任务完成：\(url.lastPathComponent)"
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
