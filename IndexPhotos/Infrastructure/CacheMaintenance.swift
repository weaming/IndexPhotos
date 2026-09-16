import Foundation

actor CacheMaintenance {
    private let catalog: CatalogStore
    private let thumbnailStore: ThumbnailStore
    private let vectorStore: VectorGenerationStore?
    private let resultIndexer: ResultIndexer?

    init(
        catalog: CatalogStore,
        thumbnailStore: ThumbnailStore,
        cacheRoot: CacheRoot? = nil
    ) {
        self.catalog = catalog
        self.thumbnailStore = thumbnailStore
        if let cacheRoot {
            vectorStore = VectorGenerationStore(cacheRoot: cacheRoot)
            resultIndexer = ResultIndexer(catalog: catalog, cacheRoot: cacheRoot)
        } else {
            vectorStore = nil
            resultIndexer = nil
        }
    }

    func deletePhotos(
        _ targets: [PhotoDeletionTarget],
        mode: PhotoDeletionMode
    ) async throws -> PhotoDeletionReport {
        var deletedAssetIDs: [String] = []
        var deletedPaths: [String] = []
        var processedPaths = Set<String>()
        var missingAssetCount = 0
        var failedPaths: [String] = []

        for target in targets {
            let url = URL(fileURLWithPath: target.path)
            if processedPaths.contains(url.path) {
                deletedAssetIDs.append(target.assetID)
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                deletedAssetIDs.append(target.assetID)
                missingAssetCount += 1
                continue
            }

            do {
                let siblingURLs = try siblingPhotoURLs(for: url)
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .fileResourceIdentifierKey,
                    .volumeIdentifierKey,
                ])
                guard values.isRegularFile == true else {
                    failedPaths.append(target.path)
                    continue
                }
                guard sourceFingerprint(for: url, values: values) == target.sourceFingerprint else {
                    failedPaths.append("\(target.path)：文件已变化，请重新扫描")
                    continue
                }

                switch mode {
                case .trash, .permanent:
                    for siblingURL in siblingURLs where !processedPaths.contains(siblingURL.path) {
                        try deleteFile(at: siblingURL, mode: mode)
                        processedPaths.insert(siblingURL.path)
                        deletedPaths.append(siblingURL.path)
                    }
                }
                deletedAssetIDs.append(target.assetID)
            } catch {
                failedPaths.append(
                    "\(target.path)：\(error.localizedDescription)"
                )
            }
        }

        if !deletedAssetIDs.isEmpty {
            _ = try await catalog.removeAssets(
                deletedAssetIDs,
                paths: deletedPaths
            )
        }
        return PhotoDeletionReport(
            deletedCount: deletedPaths.count + missingAssetCount,
            failedPaths: failedPaths
        )
    }

    func rebuildResultIndexes() async throws {
        guard let resultIndexer else {
            return
        }
        _ = try await resultIndexer.rebuild()
    }

    private func sourceFingerprint(
        for url: URL,
        values: URLResourceValues
    ) -> String {
        let resourceID = values.fileResourceIdentifier.map(String.init(describing:))
        let volumeID = values.volumeIdentifier.map(String.init(describing:)) ?? "unknown-volume"
        let identity = resourceID ?? url.standardizedFileURL.path
        let sizeBytes = Int64(values.fileSize ?? 0)
        let modificationToken = values.contentModificationDate
            .map { String($0.timeIntervalSince1970) }
            ?? "unknown-time"
        return "\(volumeID):\(identity):\(sizeBytes):\(modificationToken)"
    }

    private func siblingPhotoURLs(for url: URL) throws -> [URL] {
        let directoryURL = url.deletingLastPathComponent()
        let siblingKey = PhotoTypeRegistry.siblingKey(for: url)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter {
                PhotoTypeRegistry.isSupported($0)
                    && PhotoTypeRegistry.siblingKey(for: $0) == siblingKey
            }
            .sorted { $0.path < $1.path }
    }

    private func deleteFile(
        at url: URL,
        mode: PhotoDeletionMode
    ) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw IndexPhotosError.invalidState("不是普通照片文件：\(url.path)")
        }

        switch mode {
        case .trash:
            var resultingURL: NSURL?
            try FileManager.default.trashItem(
                at: url,
                resultingItemURL: &resultingURL
            )
        case .permanent:
            try FileManager.default.removeItem(at: url)
        }
    }

    func removeUnreferencedObjects(limit: Int = 128) async throws -> Int {
        let objects = try await catalog.unreferencedCacheObjects(limit: limit)
        var removedCount = 0

        for object in objects {
            do {
                try thumbnailStore.remove(relativePath: object.relativePath)
                try await catalog.removeCacheObject(object.key)
                removedCount += 1
            } catch {
                throw IndexPhotosError.invalidState(
                    "清理缓存对象失败 \(object.key)：\(error.localizedDescription)"
                )
            }
        }

        if let vectorStore {
            do {
                _ = try vectorStore.loadCurrent()
            } catch {
                try vectorStore.clearCurrent()
            }
            removedCount += try vectorStore.removeSupersededGenerations()
        }
        return removedCount
    }
}
