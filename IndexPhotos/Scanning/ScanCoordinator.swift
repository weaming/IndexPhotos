import Foundation

actor ScanCoordinator {
    private let catalog: CatalogStore
    private let thumbnailStore: ThumbnailStore
    private let embeddingProvider: VisionFeaturePrintProvider
    private let featureExtractor = FastFeatureExtractor()
    private let resultIndexer: ResultIndexer
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeVolumeIDs: [UUID: String] = [:]
    private var pauseRequestedRootIDs = Set<UUID>()
    private var cancelRequestedRootIDs = Set<UUID>()

    init(catalog: CatalogStore, cacheRoot: CacheRoot) {
        self.catalog = catalog
        let thumbnailStore = ThumbnailStore(cacheRoot: cacheRoot)
        self.thumbnailStore = thumbnailStore
        embeddingProvider = VisionFeaturePrintProvider()
        resultIndexer = ResultIndexer(catalog: catalog, cacheRoot: cacheRoot)
    }

    init(catalog: CatalogStore, thumbnailStore: ThumbnailStore) {
        self.catalog = catalog
        self.thumbnailStore = thumbnailStore
        embeddingProvider = VisionFeaturePrintProvider()
        resultIndexer = ResultIndexer(catalog: catalog)
    }

    func start(
        rootID: UUID,
        rootURL: URL,
        existingSessionID: UUID? = nil
    ) async throws -> ScanRun {
        guard activeTasks[rootID] == nil else {
            throw IndexPhotosError.scanAlreadyRunning
        }
        let volumeID = try volumeIdentifier(for: rootURL)
        guard !activeVolumeIDs.values.contains(volumeID) else {
            throw IndexPhotosError.scanAlreadyRunningOnVolume(rootURL)
        }

        let sessionID: UUID = if let existingSessionID {
            existingSessionID
        } else {
            try await catalog.createScanSession(rootID: rootID)
        }

        let (updates, continuation) = AsyncStream<ScanProgressSnapshot>.makeStream()
        pauseRequestedRootIDs.remove(rootID)
        cancelRequestedRootIDs.remove(rootID)
        let metrics = ScanMetrics()

        activeVolumeIDs[rootID] = volumeID
        activeTasks[rootID] = Task { [weak self] in
            guard let self else {
                continuation.finish()
                return
            }
            await run(
                sessionID: sessionID,
                rootID: rootID,
                rootURL: rootURL,
                continuation: continuation,
                metrics: metrics
            )
        }

        return ScanRun(
            id: sessionID,
            rootID: rootID,
            updates: updates,
            metrics: metrics
        )
    }

    func requestPause(rootID: UUID) {
        guard activeTasks[rootID] != nil else {
            return
        }
        pauseRequestedRootIDs.insert(rootID)
    }

    func requestCancel(rootID: UUID) {
        guard activeTasks[rootID] != nil else {
            return
        }
        cancelRequestedRootIDs.insert(rootID)
        activeTasks[rootID]?.cancel()
    }

    private func run(
        sessionID: UUID,
        rootID: UUID,
        rootURL: URL,
        continuation: AsyncStream<ScanProgressSnapshot>.Continuation,
        metrics: ScanMetrics
    ) async {
        defer {
            continuation.finish()
            activeTasks[rootID] = nil
            activeVolumeIDs[rootID] = nil
            pauseRequestedRootIDs.remove(rootID)
            cancelRequestedRootIDs.remove(rootID)
        }

        do {
            guard FileManager.default.fileExists(atPath: rootURL.path) else {
                throw IndexPhotosError.sourceUnavailable(rootURL)
            }

            _ = rootURL.startAccessingSecurityScopedResource()
            defer { rootURL.stopAccessingSecurityScopedResource() }

            try await catalog.markSessionRunning(sessionID, phase: .fastFeatures)
            try await emitProgress(for: sessionID, continuation: continuation)

            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .fileResourceIdentifierKey,
                    .volumeIdentifierKey,
                ],
                options: [.skipsPackageDescendants],
                errorHandler: { _, error in
                    enumerationError = enumerationError ?? error
                    return true
                }
            ) else {
                throw IndexPhotosError.sourceUnavailable(rootURL)
            }

            var processedItemCount = 0
            var lastProgressAt = ContinuousClock.now
            var pendingRawPhotos: [String: [DiscoveredPhoto]] = [:]
            var nonRawSiblingKeys = Set<String>()
            let cachePath = thumbnailStore.storageURL.standardizedFileURL.path
            while let item = enumerator.nextObject() as? URL {
                try Task.checkCancellation()

                if cancelRequestedRootIDs.contains(rootID) {
                    throw CancellationError()
                }

                if pauseRequestedRootIDs.contains(rootID) {
                    let snapshot = try await catalog.pauseSession(sessionID)
                    continuation.yield(snapshot)
                    return
                }

                if item.standardizedFileURL.path == cachePath {
                    enumerator.skipDescendants()
                    continue
                }
                guard PhotoTypeRegistry.isSupported(item) else {
                    continue
                }

                do {
                    guard let photo = try discoveredPhoto(item, rootID: rootID) else { continue }
                    let siblingKey = PhotoTypeRegistry.siblingKey(for: item)
                    if PhotoTypeRegistry.isRaw(item) {
                        guard !nonRawSiblingKeys.contains(siblingKey) else {
                            continue
                        }
                        pendingRawPhotos[siblingKey, default: []].append(photo)
                        continue
                    }

                    nonRawSiblingKeys.insert(siblingKey)
                    pendingRawPhotos.removeValue(forKey: siblingKey)
                    let canPublishProgress = advanceProgress(
                        processedItemCount: &processedItemCount,
                        lastProgressAt: &lastProgressAt
                    )
                    try await processDiscoveredPhoto(
                        photo,
                        sessionID: sessionID,
                        continuation: continuation,
                        shouldPublishProgress: canPublishProgress,
                        metrics: metrics
                    )
                } catch {
                    try Task.checkCancellation()
                    let snapshot = try await catalog.recordScanFailure(
                        sessionID: sessionID,
                        path: item.path,
                        message: error.localizedDescription
                    )
                    continuation.yield(snapshot)
                }
            }

            for rawPhotos in pendingRawPhotos.values {
                for photo in rawPhotos {
                    try Task.checkCancellation()
                    if cancelRequestedRootIDs.contains(rootID) {
                        throw CancellationError()
                    }
                    if pauseRequestedRootIDs.contains(rootID) {
                        let snapshot = try await catalog.pauseSession(sessionID)
                        continuation.yield(snapshot)
                        return
                    }

                    let canPublishProgress = advanceProgress(
                        processedItemCount: &processedItemCount,
                        lastProgressAt: &lastProgressAt
                    )
                    try await processDiscoveredPhoto(
                        photo,
                        sessionID: sessionID,
                        continuation: continuation,
                        shouldPublishProgress: canPublishProgress,
                        metrics: metrics
                    )
                }
            }

            try Task.checkCancellation()
            if cancelRequestedRootIDs.contains(rootID) {
                throw CancellationError()
            }
            if pauseRequestedRootIDs.contains(rootID) {
                let snapshot = try await catalog.pauseSession(sessionID)
                continuation.yield(snapshot)
                return
            }

            if let enumerationError {
                throw IndexPhotosError.invalidState("目录枚举不完整：\(enumerationError.localizedDescription)")
            }

            let missingSnapshot = try await catalog.markMissingAssets(
                rootID: rootID,
                sessionID: sessionID
            )
            continuation.yield(missingSnapshot)
            _ = try await catalog.removeMissingAssets(rootID: rootID)

            try await catalog.markSessionRunning(sessionID, phase: .embedding)
            try await emitProgress(for: sessionID, continuation: continuation)
            guard try await buildEmbeddings(
                continuation: continuation,
                sessionID: sessionID,
                rootID: rootID
            ) else {
                return
            }

            try await catalog.markSessionRunning(sessionID, phase: .index)
            try await emitProgress(for: sessionID, continuation: continuation)
            _ = try await resultIndexer.rebuild()

            try await catalog.markSessionRunning(sessionID, phase: .verify)
            try await emitProgress(for: sessionID, continuation: continuation)
            guard try await resultIndexer.verifyCandidates(
                rootID: rootID,
                shouldPause: { [weak self] in
                    await self?.isPauseRequested(rootID: rootID) ?? false
                }
            ) else {
                let snapshot = try await catalog.pauseSession(sessionID)
                continuation.yield(snapshot)
                return
            }

            try await catalog.markSessionRunning(sessionID, phase: .finalize)
            let snapshot = try await catalog.finishEnumeration(
                sessionID,
                finalPhase: .finalize
            )
            continuation.yield(snapshot)
        } catch is CancellationError {
            do {
                let snapshot = try await catalog.cancelSession(sessionID)
                continuation.yield(snapshot)
            } catch {
                continuation.finish()
            }
        } catch {
            do {
                let snapshot = try await catalog.failSession(
                    sessionID,
                    message: error.localizedDescription
                )
                continuation.yield(snapshot)
            } catch {
                continuation.finish()
            }
        }
    }

    private func buildEmbeddings(
        continuation: AsyncStream<ScanProgressSnapshot>.Continuation,
        sessionID: UUID,
        rootID: UUID
    ) async throws -> Bool {
        let inputs = try await catalog.embeddingInputs(rootID: rootID)
        var lastProgressAt = ContinuousClock.now

        for input in inputs {
            try Task.checkCancellation()
            if cancelRequestedRootIDs.contains(rootID) {
                throw CancellationError()
            }
            if pauseRequestedRootIDs.contains(rootID) {
                let snapshot = try await catalog.pauseSession(sessionID)
                continuation.yield(snapshot)
                return false
            }

            if try await catalog.validEmbedding(
                assetID: input.assetID,
                sourceFingerprint: input.sourceFingerprint,
                algorithmVersion: embeddingProvider.algorithmVersion
            ) != nil {
                continue
            }

            do {
                let thumbnailData = try thumbnailStore.load(
                    relativePath: input.thumbnailRelativePath
                )
                let embedding = try await embeddingProvider.makeEmbedding(
                    thumbnailData: thumbnailData
                )
                try await catalog.commitEmbedding(
                    assetID: input.assetID,
                    sourceFingerprint: input.sourceFingerprint,
                    embedding: embedding
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }

            let now = ContinuousClock.now
            if lastProgressAt.duration(to: now) >= .milliseconds(250) {
                lastProgressAt = now
                try await emitProgress(for: sessionID, continuation: continuation)
            }
        }
        return true
    }

    private func process(
        _ item: DiscoveredPhoto,
        sessionID: UUID,
        continuation: AsyncStream<ScanProgressSnapshot>.Continuation,
        shouldPublishProgress: Bool,
        metrics: ScanMetrics
    ) async throws {
        let registration = try await catalog.registerDiscovered(
            item,
            sessionID: sessionID
        )
        if shouldPublishProgress {
            continuation.yield(registration)
        }

        if let cachedFeature = try await catalog.validFastFeature(
            assetID: item.assetID,
            sourceFingerprint: item.sourceFingerprint,
            algorithmVersion: "fast-v1"
        ), thumbnailStore.contains(relativePath: cachedFeature.thumbnailRelativePath) {
            let snapshot = try await catalog.reuseFastFeature(
                sessionID: sessionID,
                item: item
            )
            if shouldPublishProgress {
                continuation.yield(snapshot)
            }
            try await completeContentHashIfNeeded(
                item: item,
                quickFingerprint: cachedFeature.quickFingerprint,
                metrics: metrics
            )
            return
        }

        let result: (feature: FastFeatureResult, thumbnail: ThumbnailObject)
        do {
            let worker = Task.detached(priority: .utility) { [featureExtractor, thumbnailStore] in
                try autoreleasepool {
                    let feature = try featureExtractor.extract(
                        url: URL(fileURLWithPath: item.path),
                        fileSize: item.sizeBytes
                    )
                    try Task.checkCancellation()
                    let thumbnail = try thumbnailStore.store(
                        assetID: item.assetID,
                        sourceFingerprint: item.sourceFingerprint,
                        data: feature.thumbnailData
                    )
                    return (feature: feature, thumbnail: thumbnail)
                }
            }
            result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            await metrics.addSourceBytes(result.feature.sourceBytesRead)
        } catch {
            try Task.checkCancellation()
            let snapshot = try await catalog.recordFeatureFailure(
                sessionID: sessionID,
                item: item,
                message: error.localizedDescription
            )
            continuation.yield(snapshot)
            return
        }

        let snapshot = try await catalog.commitFastFeature(
            sessionID: sessionID, item: item,
            feature: result.feature, thumbnail: result.thumbnail
        )
        if shouldPublishProgress {
            continuation.yield(snapshot)
        }
        try await completeContentHashIfNeeded(
            item: item,
            quickFingerprint: result.feature.quickFingerprint,
            metrics: metrics
        )
    }

    private func processDiscoveredPhoto(
        _ photo: DiscoveredPhoto,
        sessionID: UUID,
        continuation: AsyncStream<ScanProgressSnapshot>.Continuation,
        shouldPublishProgress: Bool = true,
        metrics: ScanMetrics
    ) async throws {
        do {
            try await process(
                photo,
                sessionID: sessionID,
                continuation: continuation,
                shouldPublishProgress: shouldPublishProgress,
                metrics: metrics
            )
        } catch {
            try Task.checkCancellation()
            let snapshot = try await catalog.recordScanFailure(
                sessionID: sessionID,
                path: photo.path,
                message: error.localizedDescription
            )
            continuation.yield(snapshot)
        }
    }

    private func advanceProgress(
        processedItemCount: inout Int,
        lastProgressAt: inout ContinuousClock.Instant
    ) -> Bool {
        processedItemCount += 1
        let now = ContinuousClock.now
        let shouldPublish = processedItemCount.isMultiple(of: 16)
            || lastProgressAt.duration(to: now) >= .milliseconds(250)
        if shouldPublish {
            lastProgressAt = now
        }
        return shouldPublish
    }

    private func completeContentHashIfNeeded(
        item: DiscoveredPhoto,
        quickFingerprint: String?,
        metrics: ScanMetrics
    ) async throws {
        guard let quickFingerprint else { return }
        let candidates = try await catalog.quickFingerprintCandidates(
            sizeBytes: item.sizeBytes,
            quickFingerprint: quickFingerprint,
            excluding: item.assetID
        )
        guard !candidates.isEmpty else { return }

        let currentHash = try await hashContent(item.path, fileSize: item.sizeBytes)
        await metrics.addSourceBytes(currentHash.sourceBytesRead)
        try await catalog.completeContentHash(
            assetID: item.assetID,
            sourceFingerprint: item.sourceFingerprint,
            contentHash: currentHash.hash
        )

        for candidate in candidates where candidate.contentHash == nil {
            do {
                let candidateHash = try await hashContent(
                    candidate.path,
                    fileSize: candidate.fileSize
                )
                await metrics.addSourceBytes(candidateHash.sourceBytesRead)
                try await catalog.completeContentHash(
                    assetID: candidate.assetID,
                    sourceFingerprint: candidate.sourceFingerprint,
                    contentHash: candidateHash.hash
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
    }

    private func hashContent(_ path: String, fileSize: Int64) async throws -> ContentHashResult {
        let worker = Task.detached(priority: .utility) { [featureExtractor] in
            try autoreleasepool {
                try featureExtractor.hash(
                    url: URL(fileURLWithPath: path),
                    fileSize: fileSize
                )
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func discoveredPhoto(_ url: URL, rootID: UUID) throws -> DiscoveredPhoto? {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .volumeIdentifierKey,
        ])

        guard values.isRegularFile == true else { return nil }

        let resourceID = values.fileResourceIdentifier.map(String.init(describing:))
        let volumeID = values.volumeIdentifier.map(String.init(describing:)) ?? "unknown-volume"
        let fallbackID = url.standardizedFileURL.path
        let identity = resourceID ?? fallbackID
        let assetID = "\(rootID.uuidString):\(volumeID):\(identity)"
        let sizeBytes = Int64(values.fileSize ?? 0)
        let modifiedAt = values.contentModificationDate
        let modificationToken = modifiedAt.map { String($0.timeIntervalSince1970) } ?? "unknown-time"
        let sourceFingerprint = "\(volumeID):\(identity):\(sizeBytes):\(modificationToken)"

        return DiscoveredPhoto(
            assetID: assetID,
            rootID: rootID,
            path: url.path,
            fileResourceID: resourceID,
            sourceFingerprint: sourceFingerprint,
            sizeBytes: sizeBytes,
            modifiedAt: modifiedAt
        )
    }

    private func emitProgress(
        for sessionID: UUID,
        continuation: AsyncStream<ScanProgressSnapshot>.Continuation
    ) async throws {
        try await continuation.yield(catalog.progress(for: sessionID))
    }

    private func isPauseRequested(rootID: UUID) -> Bool {
        pauseRequestedRootIDs.contains(rootID)
    }

    private func volumeIdentifier(for rootURL: URL) throws -> String {
        let values = try rootURL.resourceValues(forKeys: [.volumeIdentifierKey])
        return values.volumeIdentifier.map(String.init(describing:)) ?? "unknown-volume"
    }
}
