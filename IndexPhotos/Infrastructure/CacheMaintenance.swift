import Foundation

actor CacheMaintenance {
    private let catalog: CatalogStore
    private let thumbnailStore: ThumbnailStore
    private let vectorStore: VectorGenerationStore?

    init(
        catalog: CatalogStore,
        thumbnailStore: ThumbnailStore,
        cacheRoot: CacheRoot? = nil
    ) {
        self.catalog = catalog
        self.thumbnailStore = thumbnailStore
        if let cacheRoot {
            vectorStore = VectorGenerationStore(cacheRoot: cacheRoot)
        } else {
            vectorStore = nil
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
