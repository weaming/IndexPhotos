import Foundation

actor ResultIndexer {
    private let catalog: CatalogStore
    private let vectorStore: VectorGenerationStore?
    private let geometryVerifier: GeometryVerifier?

    init(catalog: CatalogStore, cacheRoot: CacheRoot? = nil) {
        self.catalog = catalog
        if let cacheRoot {
            vectorStore = VectorGenerationStore(cacheRoot: cacheRoot)
            geometryVerifier = GeometryVerifier(
                thumbnailStore: ThumbnailStore(cacheRoot: cacheRoot)
            )
        } else {
            vectorStore = nil
            geometryVerifier = nil
        }
    }

    func rebuild() async throws -> ResultIndexSummary {
        let features = try await catalog.committedFastFeatures()
        let embeddings = try await catalog.committedEmbeddings(
            algorithmVersion: VisionFeaturePrintProvider.ALGORITHM_VERSION
        )
        let fastResult = try ResultIndexBuilder.build(features: features)
        let embeddingResult = try EmbeddingIndexBuilder.buildResult(
            embeddings: embeddings
        )
        let candidates = fastResult.candidates + embeddingResult.candidates
        try await catalog.replaceResultIndex(
            groups: fastResult.groups,
            candidates: candidates
        )
        if let vectorStore {
            try vectorStore.replace(with: embeddingResult)
            _ = try vectorStore.removeSupersededGenerations()
        }
        return ResultIndexSummary(
            duplicateGroupCount: fastResult.groups.count,
            similarityCandidateCount: candidates.count
        )
    }

    func verifyCandidates(
        rootID: UUID? = nil,
        shouldPause: @Sendable () async -> Bool
    ) async throws -> Bool {
        guard let geometryVerifier else {
            return true
        }
        let candidates = try await catalog.similarityCandidates(
            rootID: rootID,
            includeReviewed: true,
            includeExact: false,
            limit: 5_000
        )
        var verifierSession = geometryVerifier.makeSession()
        for candidate in candidates {
            try Task.checkCancellation()
            if await shouldPause() {
                return false
            }
            guard let record = try verifierSession.annotate(candidate: candidate) else {
                continue
            }
            try await catalog.updateSimilarityEvidence(
                candidateID: record.candidateID,
                evidenceJSON: record.evidenceJSON
            )
        }
        return true
    }
}
