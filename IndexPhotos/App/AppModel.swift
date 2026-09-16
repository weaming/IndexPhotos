import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private static let SIMILARITY_PAGE_SIZE = 24

    let cachePath: String

    var currentProgress = ScanProgressSnapshot.idle
    var statusMessage = "正在初始化缓存…"
    var errorMessage: String?
    var savedRoots: [SavedRoot] = []
    var selectedRootURL: URL?
    var selectedRootID: UUID?
    var similarityRootIDs = Set<UUID>()
    var isSimilarityMultiSelectEnabled = false
    var resumableScans: [ResumableScan] = []
    var rootProgress: [UUID: ScanProgressSnapshot] = [:]
    var activeScanRootIDs = Set<UUID>()
    var similarityCandidates: [SimilarityReviewItem] = []
    var isLoadingSimilarityCandidates = false
    var showReviewedSimilarityCandidates = false
    var similarityAlgorithmFilter = SimilarityAlgorithmFilter.all
    var similarityScoreBucket = SimilarityScoreBucket.all
    var similarityBucketCounts = Array(
        repeating: 0,
        count: SimilarityScoreBucket.values.count
    )
    var similarityPageIndex = 0
    var similarityCandidateTotalCount = 0
    var pendingDeletionCount = 0
    var isDeletingPhotos = false
    var updatingSimilarityCandidateIDs = Set<String>()

    private let catalog: CatalogStore?
    private let coordinator: ScanCoordinator?
    private let cacheRoot: CacheRoot?
    private let cacheMaintenance: CacheMaintenance?
    let thumbnailCacheURL: URL?
    @ObservationIgnored private var similarityTask: Task<Void, Never>?
    @ObservationIgnored private var similarityRequestID = UUID()
    private var cacheLock: CacheLock?
    @ObservationIgnored private var progressTasks: [UUID: Task<Void, Never>] = [:]
    private var isSimilarityScoreBucketCustomized = false
    private var similarityPagePosition: SimilarityPagePosition = .first

    var isReady: Bool {
        catalog != nil && coordinator != nil && cacheRoot != nil
    }

    var isSelectedRootScanning: Bool {
        guard let selectedRootID else {
            return false
        }
        return activeScanRootIDs.contains(selectedRootID)
    }

    var selectedRootResumableScan: ResumableScan? {
        guard let selectedRootID else {
            return nil
        }
        return resumableScans.first { $0.rootID == selectedRootID }
    }

    func progress(for rootID: UUID) -> ScanProgressSnapshot {
        rootProgress[rootID] ?? .idle
    }

    func rootName(for rootID: UUID) -> String {
        savedRoots.first { $0.id == rootID }?.displayName ?? "照片目录"
    }

    func isSimilarityRootSelected(_ rootID: UUID) -> Bool {
        if similarityRootIDs.isEmpty {
            return selectedRootID == rootID
        }
        return similarityRootIDs.contains(rootID)
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
        guard !urls.isEmpty else {
            return
        }

        let roots = urls.map(makeSavedRoot)
        var mergedRoots = savedRoots
        for root in roots {
            if let index = mergedRoots.firstIndex(where: { $0.id == root.id }) {
                mergedRoots[index] = root
            } else {
                mergedRoots.append(root)
            }
        }
        savedRoots = mergedRoots.sorted {
            if $0.id == $1.id {
                return false
            }
            return $0.updatedAt > $1.updatedAt
        }

        if let root = roots.last {
            selectRoot(root.id)
        }
        errorMessage = nil

        guard let catalog else {
            errorMessage = "扫描服务尚未初始化。"
            return
        }
        Task { [weak self] in
            do {
                for root in roots {
                    try await catalog.upsertRoot(
                        id: root.id,
                        displayName: root.displayName,
                        url: root.url,
                        bookmarkData: root.bookmarkData
                    )
                }
                await self?.reloadRootState(using: catalog)
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func selectRoot(_ rootID: UUID) {
        guard let root = savedRoots.first(where: { $0.id == rootID }) else {
            return
        }

        selectedRootID = root.id
        selectedRootURL = resolveURL(for: root)
        if !isSimilarityMultiSelectEnabled {
            similarityRootIDs = [root.id]
        }
        if !isSimilarityScoreBucketCustomized {
            similarityScoreBucket = .all
        }
        currentProgress = progress(for: root.id)
        statusMessage = rootStatusMessage(for: root.id)
        errorMessage = nil
    }

    func setSimilarityMultiSelectEnabled(_ isEnabled: Bool) {
        isSimilarityMultiSelectEnabled = isEnabled

        if isEnabled {
            if similarityRootIDs.isEmpty, let selectedRootID {
                similarityRootIDs = [selectedRootID]
            }
        } else if let selectedRootID {
            similarityRootIDs = [selectedRootID]
        } else {
            similarityRootIDs.removeAll()
        }

        similarityPageIndex = 0
        refreshSimilarityCandidates(resetPage: true)
    }

    func toggleSimilarityRoot(_ rootID: UUID) {
        guard isSimilarityMultiSelectEnabled else {
            return
        }
        guard savedRoots.contains(where: { $0.id == rootID }) else {
            return
        }

        if similarityRootIDs.contains(rootID) {
            guard similarityRootIDs.count > 1 else {
                return
            }
            similarityRootIDs.remove(rootID)
        } else {
            similarityRootIDs.insert(rootID)
        }
        similarityPageIndex = 0
        refreshSimilarityCandidates(resetPage: true)
    }

    func startScan() {
        guard let selectedRootURL, let selectedRootID else {
            errorMessage = "请先选择一个照片目录。"
            return
        }

        beginScan(rootID: selectedRootID, rootURL: selectedRootURL)
    }

    func resumeScan() {
        guard let selectedRootID else {
            errorMessage = IndexPhotosError.noScanAvailable.localizedDescription
            return
        }
        resumeScan(for: selectedRootID)
    }

    func resumeScan(for rootID: UUID) {
        guard let resumableScan = resumableScans.first(where: { $0.rootID == rootID }) else {
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

        selectedRootID = rootID
        selectedRootURL = rootURL
        beginScan(
            rootID: rootID,
            rootURL: rootURL,
            existingSessionID: resumableScan.id
        )
    }

    func pauseScan() {
        guard let selectedRootID, activeScanRootIDs.contains(selectedRootID) else {
            errorMessage = "当前目录没有正在运行的扫描。"
            return
        }

        Task {
            await coordinator?.requestPause(rootID: selectedRootID)
        }
        statusMessage = "正在暂停，等待当前任务提交检查点…"
    }

    func cancelScan() {
        guard let selectedRootID, activeScanRootIDs.contains(selectedRootID) else {
            errorMessage = "当前目录没有正在运行的扫描。"
            return
        }

        Task {
            await coordinator?.requestCancel(rootID: selectedRootID)
        }
        statusMessage = "正在取消，保留已提交结果…"
    }

    var similarityVisibleCount: Int {
        guard let bucketIndex = similarityScoreBucket.countIndex else {
            return similarityCandidateTotalCount
        }
        return similarityBucketCounts[bucketIndex]
    }

    var similarityPageCount: Int {
        guard similarityVisibleCount > 0 else {
            return 0
        }
        return (similarityVisibleCount + Self.SIMILARITY_PAGE_SIZE - 1)
            / Self.SIMILARITY_PAGE_SIZE
    }

    var similarityPageNumber: Int {
        min(similarityPageIndex + 1, max(similarityPageCount, 1))
    }

    var hasPreviousSimilarityPage: Bool {
        similarityPageIndex > 0
    }

    var hasNextSimilarityPage: Bool {
        similarityPageIndex + 1 < similarityPageCount
    }

    func similarityBucketCount(for bucket: SimilarityScoreBucket) -> Int {
        guard let bucketIndex = bucket.countIndex else {
            return similarityCandidateTotalCount
        }
        return similarityBucketCounts[bucketIndex]
    }

    func selectSimilarityScoreBucket(_ bucket: SimilarityScoreBucket) {
        guard bucket != similarityScoreBucket else {
            return
        }
        isSimilarityScoreBucketCustomized = true
        similarityScoreBucket = bucket
        similarityPageIndex = 0
        refreshSimilarityCandidates(resetPage: true)
    }

    func selectSimilarityAlgorithmFilter(_ filter: SimilarityAlgorithmFilter) {
        guard filter != similarityAlgorithmFilter else {
            return
        }
        similarityAlgorithmFilter = filter
        similarityPageIndex = 0
        refreshSimilarityCandidates(resetPage: true)
    }

    func toggleReviewedSimilarityCandidates() {
        showReviewedSimilarityCandidates.toggle()
        similarityPageIndex = 0
        refreshSimilarityCandidates(resetPage: true)
    }

    func setSimilarityPage(_ pageIndex: Int) {
        let maximumPageIndex = max(similarityPageCount - 1, 0)
        let nextPageIndex = min(max(pageIndex, 0), maximumPageIndex)
        guard nextPageIndex != similarityPageIndex else {
            return
        }

        similarityPagePosition = if nextPageIndex == 0 {
            .first
        } else if nextPageIndex == maximumPageIndex {
            .last
        } else if nextPageIndex > similarityPageIndex,
                  let lastCandidate = similarityCandidates.last
        {
            .after(score: lastCandidate.score, id: lastCandidate.id)
        } else if let firstCandidate = similarityCandidates.first {
            .before(score: firstCandidate.score, id: firstCandidate.id)
        } else {
            .first
        }
        similarityPageIndex = nextPageIndex
        refreshSimilarityCandidates()
    }

    func isUpdatingSimilarityCandidate(_ candidateID: String) -> Bool {
        updatingSimilarityCandidateIDs.contains(candidateID)
    }

    func refreshSimilarityCandidates(resetPage: Bool = false) {
        guard let catalog else {
            similarityCandidates = []
            similarityBucketCounts = Array(
                repeating: 0,
                count: SimilarityScoreBucket.values.count
            )
            similarityCandidateTotalCount = 0
            pendingDeletionCount = 0
            similarityPageIndex = 0
            isLoadingSimilarityCandidates = false
            return
        }

        similarityTask?.cancel()
        isLoadingSimilarityCandidates = true
        if resetPage {
            similarityPageIndex = 0
            similarityPagePosition = .first
        }
        let rootIDs = similarityQueryRootIDs
        let includeReviewed = showReviewedSimilarityCandidates
        let algorithmFilter = similarityAlgorithmFilter
        let scoreBucket = similarityScoreBucket
        let pagePosition = similarityPagePosition
        let isUsingDefaultScoreBucket = !isSimilarityScoreBucketCustomized
        let pageIndex = similarityPageIndex
        let requestID = UUID()
        similarityRequestID = requestID
        similarityTask = Task { [weak self] in
            do {
                let bucketCounts = try await catalog.similarityCandidateCounts(
                    rootIDs: rootIDs,
                    includeReviewed: includeReviewed,
                    reviewedOnly: includeReviewed,
                    algorithmFilter: algorithmFilter
                )
                let resolvedBucket: SimilarityScoreBucket = if isUsingDefaultScoreBucket,
                                                                 let highestBucket = SimilarityScoreBucket.valuesDescending.first(where: {
                                                                     guard let bucketIndex = $0.countIndex else {
                                                                         return false
                                                                     }
                                                                     return bucketCounts[bucketIndex] > 0
                                                                 })
                {
                    highestBucket
                } else if let bucketIndex = scoreBucket.countIndex,
                          bucketCounts[bucketIndex] == 0
                {
                    .all
                } else {
                    scoreBucket
                }
                let visibleCount = resolvedBucket.countIndex.map {
                    bucketCounts[$0]
                } ?? bucketCounts.reduce(0, +)
                let pageCount = visibleCount > 0
                    ? (visibleCount + Self.SIMILARITY_PAGE_SIZE - 1)
                        / Self.SIMILARITY_PAGE_SIZE
                    : 0
                let resolvedPageIndex = min(
                    pageIndex,
                    max(pageCount - 1, 0)
                )
                let candidates = try await catalog.similarityCandidates(
                    rootIDs: rootIDs,
                    includeReviewed: includeReviewed,
                    reviewedOnly: includeReviewed,
                    algorithmFilter: algorithmFilter,
                    scoreBucket: resolvedBucket,
                    pagePosition: pagePosition,
                    limit: Self.SIMILARITY_PAGE_SIZE
                )
                let deletionTargets = includeReviewed
                    ? try await catalog.similarityDeletionTargets(
                        rootIDs: rootIDs,
                        algorithmFilter: algorithmFilter,
                        scoreBucket: resolvedBucket
                    )
                    : []
                guard !Task.isCancelled,
                      let self,
                      self.similarityRequestID == requestID
                else {
                    return
                }
                self.similarityBucketCounts = bucketCounts
                self.similarityCandidateTotalCount = bucketCounts.reduce(0, +)
                self.pendingDeletionCount = deletionTargets.count
                self.similarityAlgorithmFilter = algorithmFilter
                self.similarityScoreBucket = resolvedBucket
                self.similarityPageIndex = resolvedPageIndex
                self.similarityCandidates = candidates
                self.isLoadingSimilarityCandidates = false
            } catch is CancellationError {
            } catch {
                guard let self, self.similarityRequestID == requestID else {
                    return
                }
                self.isLoadingSimilarityCandidates = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private var similarityQueryRootIDs: [UUID]? {
        if !similarityRootIDs.isEmpty {
            return similarityRootIDs.sorted { $0.uuidString < $1.uuidString }
        }
        return selectedRootID.map { [$0] }
    }

    func executePendingDeletions(mode: PhotoDeletionMode) {
        guard !isDeletingPhotos else {
            return
        }
        guard let catalog, let cacheMaintenance else {
            errorMessage = "删除服务尚未初始化。"
            return
        }

        let rootIDs = similarityQueryRootIDs
        let algorithmFilter = similarityAlgorithmFilter
        let scoreBucket = similarityScoreBucket
        isDeletingPhotos = true
        errorMessage = nil

        Task { [weak self] in
            do {
                let targets = try await catalog.similarityDeletionTargets(
                    rootIDs: rootIDs,
                    algorithmFilter: algorithmFilter,
                    scoreBucket: scoreBucket
                )
                let report = try await cacheMaintenance.deletePhotos(
                    targets,
                    mode: mode
                )
                try await cacheMaintenance.rebuildResultIndexes()
                _ = try await cacheMaintenance.removeUnreferencedObjects(limit: 4_096)

                guard let self else {
                    return
                }
                if report.failedPaths.isEmpty {
                    self.statusMessage = "已\(mode.title) \(report.deletedCount) 张照片"
                } else {
                    self.errorMessage = "已处理 \(report.deletedCount) 张照片，以下文件失败：\n"
                        + report.failedPaths.joined(separator: "\n")
                }
                self.isDeletingPhotos = false
                self.refreshSimilarityCandidates(resetPage: true)
            } catch {
                guard let self else {
                    return
                }
                self.isDeletingPhotos = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func removeSavedRoot(_ rootID: UUID) {
        guard !activeScanRootIDs.contains(rootID) else {
            errorMessage = "请先停止该目录的扫描，再移除目录索引。"
            return
        }
        guard let catalog, let cacheMaintenance else {
            errorMessage = "目录服务尚未初始化。"
            return
        }

        Task { [weak self] in
            do {
                _ = try await catalog.removeRoot(rootID)
                try await cacheMaintenance.rebuildResultIndexes()
                _ = try await cacheMaintenance.removeUnreferencedObjects(limit: 4_096)

                guard let self else {
                    return
                }
                self.savedRoots.removeAll { $0.id == rootID }
                self.resumableScans.removeAll { $0.rootID == rootID }
                self.rootProgress[rootID] = nil
                self.similarityRootIDs.remove(rootID)

                if self.selectedRootID == rootID {
                    self.selectedRootID = nil
                    self.selectedRootURL = nil
                    self.currentProgress = .idle
                    self.statusMessage = "目录索引已移除"
                    if let nextRoot = self.savedRoots.first {
                        self.selectRoot(nextRoot.id)
                        if self.isSimilarityMultiSelectEnabled {
                            self.similarityRootIDs = [nextRoot.id]
                        }
                    }
                } else if let selectedRootID = self.selectedRootID,
                          self.similarityRootIDs.isEmpty
                {
                    self.similarityRootIDs = [selectedRootID]
                }
                self.refreshSimilarityCandidates(resetPage: true)
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func reviewCandidate(_ candidateID: String, decision: ReviewDecision) {
        guard let catalog else {
            errorMessage = "审核服务尚未初始化。"
            return
        }
        guard !updatingSimilarityCandidateIDs.contains(candidateID) else {
            return
        }

        updatingSimilarityCandidateIDs.insert(candidateID)
        Task { [weak self] in
            var didSucceed = false
            do {
                try await catalog.setReviewDecision(
                    candidateID: candidateID,
                    decision: decision
                )
                didSucceed = true
            } catch {
                if !Task.isCancelled {
                    self?.errorMessage = error.localizedDescription
                }
            }
            guard let self else {
                return
            }
            self.updatingSimilarityCandidateIDs.remove(candidateID)
            if didSucceed, !Task.isCancelled {
                self.refreshSimilarityCandidates()
            }
        }
    }

    func clearReviewDecision(_ candidateID: String) {
        guard let catalog else {
            errorMessage = "审核服务尚未初始化。"
            return
        }
        guard !updatingSimilarityCandidateIDs.contains(candidateID) else {
            return
        }

        updatingSimilarityCandidateIDs.insert(candidateID)
        Task { [weak self] in
            var didSucceed = false
            do {
                try await catalog.clearReviewDecision(candidateID: candidateID)
                didSucceed = true
            } catch {
                if !Task.isCancelled {
                    self?.errorMessage = error.localizedDescription
                }
            }
            guard let self else {
                return
            }
            self.updatingSimilarityCandidateIDs.remove(candidateID)
            if didSucceed, !Task.isCancelled {
                self.refreshSimilarityCandidates()
            }
        }
    }

    private func beginScan(
        rootID: UUID,
        rootURL: URL,
        existingSessionID: UUID? = nil
    ) {
        guard !activeScanRootIDs.contains(rootID) else {
            errorMessage = IndexPhotosError.scanAlreadyRunning.localizedDescription
            return
        }

        guard let catalog, let coordinator else {
            errorMessage = "扫描服务尚未初始化。"
            return
        }

        activeScanRootIDs.insert(rootID)
        errorMessage = nil
        if selectedRootID == rootID {
            statusMessage = "正在准备扫描…"
            currentProgress = progress(for: rootID)
        }

        progressTasks[rootID] = Task { [weak self] in
            defer {
                self?.finishScan(rootID: rootID)
            }

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
                    self?.apply(snapshot, for: rootID)
                }

                if self?.rootProgress[rootID]?.status == .completed,
                   self?.selectedRootID == rootID
                {
                    do {
                        let summary = try await catalog.resultSummary()
                        self?.statusMessage = "扫描完成：\(summary.duplicateGroupCount) 个重复组，\(summary.similarityCandidateCount) 个相似候选"
                        self?.refreshSimilarityCandidates()
                    } catch {
                        self?.errorMessage = error.localizedDescription
                    }
                }

                if self?.rootProgress[rootID]?.status == .completed,
                   let maintenance = self?.cacheMaintenance
                {
                    do {
                        _ = try await maintenance.removeUnreferencedObjects(limit: 4_096)
                    } catch {
                        self?.errorMessage = error.localizedDescription
                    }
                }

                await self?.reloadRootState(using: catalog)
            } catch {
                if self?.selectedRootID == rootID {
                    self?.errorMessage = error.localizedDescription
                    self?.statusMessage = "扫描启动失败"
                }
            }
        }
    }

    private func finishScan(rootID: UUID) {
        activeScanRootIDs.remove(rootID)
        progressTasks[rootID] = nil
    }

    private func restoreInterruptedScan(
        using catalog: CatalogStore,
        maintenance: CacheMaintenance?
    ) async {
        do {
            try await catalog.recoverInterruptedSessions()
            savedRoots = try await catalog.savedRoots()
            rootProgress = try await catalog.latestScanProgressesByRoot()
            resumableScans = try await catalog.resumableScans()

            if selectedRootID == nil, let firstRoot = savedRoots.first {
                selectRoot(firstRoot.id)
            }

            if let maintenance {
                do {
                    _ = try await maintenance.removeUnreferencedObjects()
                } catch {
                    errorMessage = error.localizedDescription
                    statusMessage = "缓存已就绪，但清理未完成"
                    return
                }
            }

            if !resumableScans.isEmpty {
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

    private func reloadRootState(using catalog: CatalogStore) async {
        do {
            savedRoots = try await catalog.savedRoots()
            rootProgress = try await catalog.latestScanProgressesByRoot()
            resumableScans = try await catalog.resumableScans()
            if let selectedRootID,
               let progress = rootProgress[selectedRootID]
            {
                currentProgress = progress
                statusMessage = rootStatusMessage(for: selectedRootID)
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ snapshot: ScanProgressSnapshot, for rootID: UUID) {
        rootProgress[rootID] = snapshot
        guard selectedRootID == rootID else {
            return
        }

        currentProgress = snapshot

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

    private func makeSavedRoot(_ url: URL) -> SavedRoot {
        SavedRoot(
            id: StableIdentifier.rootID(for: url),
            displayName: url.lastPathComponent,
            url: url,
            bookmarkData: try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ),
            updatedAt: .now
        )
    }

    private func resolveURL(for root: SavedRoot) -> URL {
        guard let bookmarkData = root.bookmarkData else {
            return root.url
        }

        var isStale = false
        return (try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )) ?? root.url
    }

    private func rootStatusMessage(for rootID: UUID) -> String {
        guard let progress = rootProgress[rootID] else {
            return "尚未扫描"
        }

        switch progress.status {
        case .queued, .running, .pausing, .recovering:
            return phaseMessage(progress.phase)
        case .paused:
            return "已暂停，可继续"
        case .cancelled:
            return "已取消"
        case .completed:
            return "已完成"
        case .failed:
            return "扫描失败"
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
