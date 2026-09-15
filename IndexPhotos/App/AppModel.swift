import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let cachePath: String

    var currentProgress = ScanProgressSnapshot.idle
    var statusMessage = "正在初始化缓存…"
    var errorMessage: String?
    var selectedRootURL: URL?
    var selectedRootID: UUID?
    var resumableScan: ResumableScan?
    var isScanTaskActive = false
    var similarityCandidates: [SimilarityReviewItem] = []
    var isLoadingSimilarityCandidates = false
    var showReviewedSimilarityCandidates = false

    private let catalog: CatalogStore?
    private let coordinator: ScanCoordinator?
    private let cacheRoot: CacheRoot?
    private let cacheMaintenance: CacheMaintenance?
    let thumbnailCacheURL: URL?
    @ObservationIgnored private var similarityTask: Task<Void, Never>?
    private var cacheLock: CacheLock?
    private var progressTask: Task<Void, Never>?

    var isReady: Bool {
        catalog != nil && coordinator != nil && cacheRoot != nil
    }

    var isScanning: Bool {
        isScanTaskActive
    }

    init() {
        var resolvedCacheRoot: CacheRoot?
        var resolvedCatalog: CatalogStore?
        var resolvedCoordinator: ScanCoordinator?
        var resolvedMaintenance: CacheMaintenance?
        var resolvedLock: CacheLock?
        var initializationError: Error?

        do {
            let cacheRoot = try CacheRoot()
            try cacheRoot.prepare()
            let cacheLock = try CacheLock(url: cacheRoot.paths.lock)
            let catalog = try CatalogStore(databaseURL: cacheRoot.paths.database)

            resolvedCacheRoot = cacheRoot
            resolvedLock = cacheLock
            resolvedCatalog = catalog
            resolvedCoordinator = ScanCoordinator(catalog: catalog, cacheRoot: cacheRoot)
            resolvedMaintenance = CacheMaintenance(
                catalog: catalog,
                thumbnailStore: ThumbnailStore(cacheRoot: cacheRoot),
                cacheRoot: cacheRoot
            )
        } catch {
            initializationError = error
        }

        cacheRoot = resolvedCacheRoot
        thumbnailCacheURL = resolvedCacheRoot?.paths.root
        cacheLock = resolvedLock
        catalog = resolvedCatalog
        coordinator = resolvedCoordinator
        cacheMaintenance = resolvedMaintenance
        cachePath = resolvedCacheRoot?.paths.root.path ?? "~/.index-photos"

        if let initializationError {
            errorMessage = initializationError.localizedDescription
            statusMessage = "缓存初始化失败"
        } else if let catalog = resolvedCatalog {
            Task { [weak self] in
                await self?.restoreInterruptedScan(
                    using: catalog,
                    maintenance: resolvedMaintenance
                )
            }
        }
    }

    func selectDirectory(_ urls: [URL]) {
        guard let url = urls.first else {
            return
        }

        selectedRootURL = url
        selectedRootID = StableIdentifier.rootID(for: url)
        statusMessage = "已选择目录：\(url.path)"
        errorMessage = nil
    }

    func startScan() {
        guard let selectedRootURL, let selectedRootID else {
            errorMessage = "请先选择一个照片目录。"
            return
        }

        beginScan(rootID: selectedRootID, rootURL: selectedRootURL)
    }

    func resumeScan() {
        guard let resumableScan else {
            errorMessage = IndexPhotosError.noScanAvailable.localizedDescription
            return
        }

        var rootURL = resumableScan.rootURL
        if let bookmarkData = resumableScan.bookmarkData {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                rootURL = resolvedURL
            }
        }

        selectedRootURL = rootURL
        selectedRootID = resumableScan.rootID
        beginScan(
            rootID: resumableScan.rootID,
            rootURL: rootURL,
            existingSessionID: resumableScan.id
        )
    }

    func pauseScan() {
        guard isScanning else {
            return
        }

        Task {
            await coordinator?.requestPause()
        }
        statusMessage = "正在暂停，等待当前任务提交检查点…"
    }

    func cancelScan() {
        guard isScanning else {
            return
        }

        Task {
            await coordinator?.requestCancel()
        }
        statusMessage = "正在取消，保留已提交结果…"
    }

    func refreshSimilarityCandidates() {
        guard let catalog else {
            similarityCandidates = []
            isLoadingSimilarityCandidates = false
            return
        }

        similarityTask?.cancel()
        isLoadingSimilarityCandidates = true
        let rootID = selectedRootID
        let includeReviewed = showReviewedSimilarityCandidates
        similarityTask = Task { [weak self] in
            do {
                let candidates = try await catalog.similarityCandidates(
                    rootID: rootID,
                    includeReviewed: includeReviewed
                )
                guard !Task.isCancelled else {
                    return
                }
                self?.similarityCandidates = candidates
                self?.isLoadingSimilarityCandidates = false
            } catch is CancellationError {
            } catch {
                self?.isLoadingSimilarityCandidates = false
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func reviewCandidate(_ candidateID: String, decision: ReviewDecision) {
        guard let catalog else {
            errorMessage = "审核服务尚未初始化。"
            return
        }

        Task { [weak self] in
            do {
                try await catalog.setReviewDecision(
                    candidateID: candidateID,
                    decision: decision
                )
                guard !Task.isCancelled else {
                    return
                }
                self?.refreshSimilarityCandidates()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func clearReviewDecision(_ candidateID: String) {
        guard let catalog else {
            errorMessage = "审核服务尚未初始化。"
            return
        }

        Task { [weak self] in
            do {
                try await catalog.clearReviewDecision(candidateID: candidateID)
                guard !Task.isCancelled else {
                    return
                }
                self?.refreshSimilarityCandidates()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func beginScan(
        rootID: UUID,
        rootURL: URL,
        existingSessionID: UUID? = nil
    ) {
        guard !isScanning else {
            errorMessage = IndexPhotosError.scanAlreadyRunning.localizedDescription
            return
        }

        guard let catalog, let coordinator else {
            errorMessage = "扫描服务尚未初始化。"
            return
        }

        progressTask?.cancel()
        isScanTaskActive = true
        errorMessage = nil
        statusMessage = "正在准备扫描…"

        progressTask = Task { [weak self] in
            do {
                let bookmarkData = try? rootURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )

                try await catalog.upsertRoot(
                    id: rootID,
                    displayName: rootURL.lastPathComponent,
                    url: rootURL,
                    bookmarkData: bookmarkData
                )

                let run = try await coordinator.start(
                    rootID: rootID,
                    rootURL: rootURL,
                    existingSessionID: existingSessionID
                )

                for await snapshot in run.updates {
                    guard !Task.isCancelled else {
                        return
                    }
                    self?.apply(snapshot)
                }

                if self?.currentProgress.status == .completed {
                    do {
                        let summary = try await catalog.resultSummary()
                        self?.statusMessage = "扫描完成：\(summary.duplicateGroupCount) 个重复组，\(summary.similarityCandidateCount) 个相似候选"
                        self?.refreshSimilarityCandidates()
                    } catch {
                        self?.errorMessage = error.localizedDescription
                    }
                }

                self?.isScanTaskActive = false
                self?.resumableScan = try? await catalog.latestResumableScan()
            } catch {
                self?.isScanTaskActive = false
                self?.errorMessage = error.localizedDescription
                self?.statusMessage = "扫描启动失败"
            }
        }
    }

    private func restoreInterruptedScan(
        using catalog: CatalogStore,
        maintenance: CacheMaintenance?
    ) async {
        do {
            try await catalog.recoverInterruptedSessions()
            resumableScan = try await catalog.latestResumableScan()

            if let maintenance {
                do {
                    _ = try await maintenance.removeUnreferencedObjects()
                } catch {
                    errorMessage = error.localizedDescription
                    statusMessage = "缓存已就绪，但清理未完成"
                    return
                }
            }

            if resumableScan != nil {
                statusMessage = "发现可继续的扫描任务"
            } else {
                statusMessage = "缓存已就绪"
            }
            refreshSimilarityCandidates()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "无法恢复扫描状态"
        }
    }

    private func apply(_ snapshot: ScanProgressSnapshot) {
        currentProgress = snapshot
        resumableScan = nil

        switch snapshot.status {
        case .running:
            statusMessage = phaseMessage(snapshot.phase)
        case .paused:
            statusMessage = "扫描已暂停，可从检查点继续"
        case .cancelled:
            statusMessage = "扫描已取消，已保留已提交结果"
        case .completed:
            statusMessage = "扫描完成，已提交 \(snapshot.committedCount) 个文件"
        case .failed:
            statusMessage = "扫描失败"
        case .queued, .pausing, .recovering:
            statusMessage = phaseMessage(snapshot.phase)
        }
    }

    private func phaseMessage(_ phase: ScanPhase) -> String {
        switch phase {
        case .prepare:
            return "正在准备扫描…"
        case .enumerate:
            return "正在登记照片文件…"
        case .fastFeatures:
            return "正在计算快速特征…"
        case .embedding:
            return "正在计算相似度向量…"
        case .index:
            return "正在更新向量索引…"
        case .verify:
            return "正在复核相似候选…"
        case .finalize:
            return "正在整理扫描结果…"
        }
    }
}
